#!/usr/bin/env bash
#
# Cross-check our signature threshold against Bitcoin Core's own verify.py.
#
# WHY: scripts/verify.sh and the Dockerfile implement the threshold check by
# hand. Hand-rolled gpg status parsing is subtle — on 2026-09-12 ours counted 7
# of 11 valid signatures because it matched the signing SUBKEY fingerprint
# against an allowlist of PRIMARY fingerprints, and nothing in the repo noticed.
# A second, independent implementation disagreeing is how that class of bug gets
# caught. This is belt and braces, not a replacement: verify.sh remains the gate.
#
# NOTE ON WHAT VERIFY.PY ACTUALLY ENFORCES. Its threshold counts every good
# signature in the keyring, not only those named by --trusted-keys:
#
#   good_trusted   = [sig for sig in good if sig.trusted or sig.key in trusted_keys]
#   good_untrusted = [sig for sig in good if sig not in good_trusted]
#   num_trusted    = len(good_trusted) + len(good_untrusted)   # == len(good)
#
# Those two lists partition `good`, so --trusted-keys only affects labelling.
# Trust therefore comes from which keys are in the keyring. To make the
# comparison meaningful we build a keyring containing ONLY the fingerprints on
# our allowlist, so both implementations see the same candidate signer set and
# the counts are directly comparable.
#
# Runs on a CONNECTED machine (it downloads verify.py at a pinned revision).
# Never runs inside the container build — invariant 1 stands.
#
#   usage: scripts/cross-check-verify-py.sh <version> [triple]
#
set -euo pipefail

# Pinned upstream revision of contrib/verify-binaries/verify.py. Bumping these
# two values is a reviewed commit: read the diff first.
VERIFY_PY_COMMIT="facaf5621446d819440f5a873848c01c848c3ecc"
VERIFY_PY_SHA256="f35fbf10740b86548e068fc689272cbbe5de012f86b8e4fea01103f7530d7409"

VERSION="${1:?usage: cross-check-verify-py.sh <version> [triple]}"
TRIPLE="${2:-x86_64-linux-gnu}"
MIN_GOOD_SIGS="${MIN_GOOD_SIGS:-6}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${UPSTREAM_DIR:-${REPO_ROOT}/upstream}"
KEYS="${KEYS:-${REPO_ROOT}/keys}"
TARBALL="${UPSTREAM_DIR}/bitcoin-${VERSION}-${TRIPLE}.tar.gz"

for f in "${UPSTREAM_DIR}/SHA256SUMS" "${UPSTREAM_DIR}/SHA256SUMS.asc" "${TARBALL}"; do
  [[ -f "${f}" ]] || { echo "missing ${f}" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 required for the cross-check" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo ">> fetching verify.py @ ${VERIFY_PY_COMMIT:0:12}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  -o "${tmp}/verify.py" \
  "https://raw.githubusercontent.com/bitcoin/bitcoin/${VERIFY_PY_COMMIT}/contrib/verify-binaries/verify.py"

got="$(sha256sum "${tmp}/verify.py" | cut -d' ' -f1)"
if [[ "${got}" != "${VERIFY_PY_SHA256}" ]]; then
  echo "FATAL: verify.py hash mismatch" >&2
  echo "  expected ${VERIFY_PY_SHA256}" >&2
  echo "  got      ${got}" >&2
  exit 1
fi
echo "   sha256 ok"

# Keyring of ONLY allowlisted primary keys, so both tools see the same set.
allowed="$(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' \
           "${KEYS}/trusted-fingerprints.txt" | sort -u)"
[[ -n "${allowed}" ]] || { echo "allowlist is empty — nothing to cross-check" >&2; exit 1; }

export GNUPGHOME="${tmp}/gnupg"
mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
n_keys=0
while read -r fpr; do
  [[ -f "${KEYS}/${fpr}.asc" ]] || { echo "   warn: no key file for ${fpr}" >&2; continue; }
  gpg --batch --quiet --import "${KEYS}/${fpr}.asc" 2>/dev/null && n_keys=$((n_keys+1))
done <<< "${allowed}"
echo ">> keyring built from allowlist: ${n_keys} keys"

echo ">> running verify.py bin"
set +e
BINVERIFY_MIN_GOOD_SIGS="${MIN_GOOD_SIGS}" \
  python3 "${tmp}/verify.py" \
    --min-good-sigs "${MIN_GOOD_SIGS}" \
    bin \
    -s "${UPSTREAM_DIR}/SHA256SUMS.asc" \
    "${UPSTREAM_DIR}/SHA256SUMS" \
    "${TARBALL}" > "${tmp}/vp.out" 2>&1
vp_rc=$?
set -e

vp_count="$(grep -oE 'got [0-9]+ good signatures' "${tmp}/vp.out" | grep -oE '[0-9]+' | head -1 || true)"

# Our count comes from running the REAL gate, not from re-deriving it here. An
# earlier draft of this script recomputed the signer set inline and forgot to
# intersect it with the allowlist — so it reported 11 either way and would not
# have caught the very subkey bug that motivated this cross-check. Comparing
# against a third implementation proves nothing about the two that ship.
echo ">> running scripts/verify.sh"
set +e
MIN_GOOD_SIGS="${MIN_GOOD_SIGS}" "${REPO_ROOT}/scripts/verify.sh" \
  "${VERSION}" "${TRIPLE}" > "${tmp}/ours.out" 2>&1
ours_rc=$?
set -e
ours_count="$(sed -n 's/^accepted signers (\([0-9]\+\),.*/\1/p' "${tmp}/ours.out" | head -1)"
[[ -n "${ours_count}" ]] || {
  echo "could not parse verify.sh output:" >&2; cat "${tmp}/ours.out" >&2; exit 1; }

echo
printf 'verify.py good signatures : %s (exit %d)\n' "${vp_count:-?}" "${vp_rc}"
printf 'our accepted signers      : %s\n' "${ours_count}"
printf 'threshold                 : %s\n' "${MIN_GOOD_SIGS}"

ours_pass=$([[ "${ours_rc}" -eq 0 ]] && echo pass || echo fail)
vp_pass=$([[ "${vp_rc}" -eq 0 ]] && echo pass || echo fail)

echo
if [[ "${ours_pass}" != "${vp_pass}" ]]; then
  echo "--- verify.py output ---"; cat "${tmp}/vp.out"
  echo
  echo "FAIL — implementations DISAGREE on the verdict (ours=${ours_pass}, verify.py=${vp_pass})" >&2
  exit 1
fi

if [[ -n "${vp_count}" && "${vp_count}" != "${ours_count}" ]]; then
  echo "WARNING — same verdict (${ours_pass}) but different counts:" >&2
  echo "  verify.py ${vp_count} vs ours ${ours_count}" >&2
  echo "  Both tools saw the same keyring, so this is worth understanding." >&2
  echo "  Expired or revoked keys are one known cause: verify.py folds" >&2
  echo "  EXPKEYSIG/REVKEYSIG into its good tally." >&2
  exit 1
fi

echo "OK — verify.py agrees: ${ours_count} signatures, verdict ${ours_pass}"
