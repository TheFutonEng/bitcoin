#!/usr/bin/env bash
#
# Verify the staged Bitcoin Core release artifacts in upstream/.
#
# This mirrors the check baked into the Dockerfile. Having it standalone means
# you can run it in CI, on an air-gapped host, or as a pre-commit gate without
# spinning a container. Keep the two in sync — if you change the threshold
# logic here, change it in the Dockerfile too.
#
#   usage: scripts/verify.sh 31.1 [x86_64-linux-gnu]
#
set -euo pipefail

VERSION="${1:?usage: verify.sh <version> [triple]}"
TRIPLE="${2:-x86_64-linux-gnu}"
# 6 matches bitcoin/bitcoin's `verify.py --min-good-sigs 6`. Keep in sync with
# the ARG default in the Dockerfile and MIN_GOOD_SIGS in the Makefile.
MIN_GOOD_SIGS="${MIN_GOOD_SIGS:-6}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${REPO_ROOT}/upstream"
KEYS="${REPO_ROOT}/keys"
TARBALL="bitcoin-${VERSION}-${TRIPLE}.tar.gz"

for f in SHA256SUMS SHA256SUMS.asc "${TARBALL}"; do
  [[ -f "${UPSTREAM}/${f}" ]] || { echo "missing upstream/${f}" >&2; exit 1; }
done

shopt -s nullglob
keyfiles=("${KEYS}"/*.asc)
(( ${#keyfiles[@]} > 0 )) || { echo "no keys in keys/ — run scripts/import-builder-keys.sh" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT

gpg --batch --quiet --import "${keyfiles[@]}"

status="$(mktemp)"
gpg --batch --status-fd 1 --verify \
    "${UPSTREAM}/SHA256SUMS.asc" "${UPSTREAM}/SHA256SUMS" >"${status}" 2>/dev/null || true

# Primary-key fingerprints with a cryptographically valid signature over
# SHA256SUMS.
#
# Field 3 of VALIDSIG is the key that MADE the signature, which is the signing
# SUBKEY whenever a builder signs with one — and several Core builders do
# (fanquake, Emzy, willcl-ark, TheCharlatan on 31.1). The allowlist holds
# PRIMARY fingerprints, so matching on $3 silently discards those signatures:
# on 31.1 it counts 7 of 11. The last field is the primary key's fingerprint,
# which is what the allowlist is expressed in. Deduping on the primary also
# means one builder signing with two subkeys still counts once.
# Signatures from EXPIRED or REVOKED keys do not count. gpg emits BOTH
# EXPKEYSIG and VALIDSIG for an expired key — verified by construction
# 2026-09-20 with a key given a 2-second lifetime — so a parser reading only
# VALIDSIG counts them. `bad` is scoped by NEWSIG, which begins each signature
# block, so the flag applies to that signature only.
#
# This is a policy choice, not just a bug fix: a signature made while a key was
# valid is arguably still evidence. It is rejected anyway, because an expired or
# revoked builder key is one whose owner may have stopped maintaining it, and
# the threshold is meant to measure people who currently vouch for the bytes.
# It costs nothing today: all 10 allowlisted signers of 31.1 are current.
signers="$(awk '
  /^\[GNUPG:\] NEWSIG/                { bad = 0 }
  /^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG)/ { bad = 1 }
  /^\[GNUPG:\] VALIDSIG/ { if (!bad) print (NF >= 12 ? $NF : $3) }
' "${status}" | sort -u)"

# The hand-reviewed allowlist. Importable != trusted.
allowed="$(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' "${KEYS}/trusted-fingerprints.txt" | sort -u)"

accepted="$(comm -12 <(echo "${signers}") <(echo "${allowed}"))"
count="$(printf '%s\n' "${accepted}" | grep -c . || true)"

echo "accepted signers (${count}, minimum ${MIN_GOOD_SIGS}):"
if [[ -n "${accepted}" ]]; then printf '%s\n' "${accepted}" | sed 's/^/  /'
else echo "  (none)"; fi

unknown="$(comm -23 <(echo "${signers}") <(echo "${allowed}") | grep -c . || true)"
if (( unknown > 0 )); then
  echo
  echo "note: ${unknown} valid signature(s) from keys NOT on your allowlist:"
  comm -23 <(echo "${signers}") <(echo "${allowed}") | sed 's/^/  /'
  echo "  (these are ignored — add deliberately if you have verified them)"
fi

if (( count < MIN_GOOD_SIGS )); then
  echo >&2
  echo "FATAL: signature threshold not met" >&2
  exit 1
fi

echo
echo "checking tarball digest against SHA256SUMS"
( cd "${UPSTREAM}" && grep "  ${TARBALL}\$" SHA256SUMS | sha256sum -c - )

digest="$(sha256sum "${UPSTREAM}/${TARBALL}" | cut -d' ' -f1)"

# Provenance record. Attach this to the image with `cosign attest` so the
# signer set and upstream digest travel with the artifact into the air gap.
cat > "${REPO_ROOT}/provenance.json" <<EOF
{
  "upstream": "bitcoincore.org",
  "version": "${VERSION}",
  "triple": "${TRIPLE}",
  "tarball": "${TARBALL}",
  "tarball_sha256": "${digest}",
  "signature_threshold": ${MIN_GOOD_SIGS},
  "accepted_signers": [$(printf '%s\n' "${accepted}" | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)],
  "verified_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo
echo "OK — provenance.json written"
