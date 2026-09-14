#!/usr/bin/env bash
#
# Pull a Bitcoin Core release into upstream/ and verify it.
#
# This runs on a CONNECTED machine, once per version bump. The output of this
# script is meant to be reviewed and committed, so that the container build
# itself needs no network access and the exact bytes that went into an image
# are visible in git history.
#
#   usage: scripts/fetch-release.sh 31.1 [x86_64-linux-gnu]
#
set -euo pipefail

VERSION="${1:?usage: fetch-release.sh <version> [triple]}"
TRIPLE="${2:-x86_64-linux-gnu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${REPO_ROOT}/upstream"
BASE_URL="https://bitcoincore.org/bin/bitcoin-core-${VERSION}"
TARBALL="bitcoin-${VERSION}-${TRIPLE}.tar.gz"

mkdir -p "${UPSTREAM}"

fetch() {
  echo ">> GET ${BASE_URL}/$1"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
       --output "${UPSTREAM}/$1" "${BASE_URL}/$1"
}

# Signed sums first. bitcoincore.org withdraws releases — 30.0 and 30.1 are gone
# from its index as of 2026-09-12 — but guix.sigs retains the attestations, so
# fall back to reconstructing them from there.
if fetch SHA256SUMS && fetch SHA256SUMS.asc; then
  echo ">> sums from bitcoincore.org"
else
  echo
  echo ">> bitcoincore.org has no sums for ${VERSION} — falling back to guix.sigs"
  rm -f "${UPSTREAM}/SHA256SUMS" "${UPSTREAM}/SHA256SUMS.asc"
  "${REPO_ROOT}/scripts/fetch-sums-from-guix-sigs.sh" "${VERSION}" "${UPSTREAM}"
fi

# The tarball has no fallback. guix.sigs stores attestations, not binaries.
if ! fetch "${TARBALL}"; then
  echo >&2
  echo "FATAL: ${TARBALL} is not available from bitcoincore.org." >&2
  echo >&2
  echo "The signed sums above still tell you its correct hash, but the bytes" >&2
  echo "must come from somewhere else — your own published image, or an" >&2
  echo "archive you kept. Put the file at:" >&2
  echo "  ${UPSTREAM}/${TARBALL}" >&2
  echo "and re-run scripts/verify.sh; it is checked against these sums." >&2
  exit 1
fi

echo
echo ">> verifying before this is allowed anywhere near a build"
"${REPO_ROOT}/scripts/verify.sh" "${VERSION}" "${TRIPLE}"

# Independent second opinion from Core's own verify.py. Our threshold check is
# hand-rolled; a second implementation disagreeing is how parsing bugs surface.
# Set SKIP_CROSS_CHECK=1 only if GitHub is unreachable, and say so in review.
if [[ "${SKIP_CROSS_CHECK:-0}" == "1" ]]; then
  echo
  echo ">> SKIPPING verify.py cross-check (SKIP_CROSS_CHECK=1)"
else
  echo
  echo ">> cross-checking against Bitcoin Core's verify.py"
  "${REPO_ROOT}/scripts/cross-check-verify-py.sh" "${VERSION}" "${TRIPLE}"
fi

cat <<EOF

Done. Next steps:
  1. Read scripts/verify.sh output above. Confirm the signer fingerprints are
     ones you have independently seen before (guix.sigs history, prior
     releases, out-of-band sources). A brand new fingerprint is a question,
     not a formality.
  2. Confirm verify.sh and verify.py agreed on the signature count above.
     A disagreement is a parsing bug in one of them, not a formality.
  3. git add upstream/ && git commit
  4. make build VERSION=${VERSION}
EOF
