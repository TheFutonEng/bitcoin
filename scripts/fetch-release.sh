#!/usr/bin/env bash
#
# Pull a Bitcoin Core release into vendor/ and verify it.
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
VENDOR="${REPO_ROOT}/vendor"
BASE_URL="https://bitcoincore.org/bin/bitcoin-core-${VERSION}"
TARBALL="bitcoin-${VERSION}-${TRIPLE}.tar.gz"

mkdir -p "${VENDOR}"

fetch() {
  echo ">> GET ${BASE_URL}/$1"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
       --output "${VENDOR}/$1" "${BASE_URL}/$1"
}

fetch SHA256SUMS
fetch SHA256SUMS.asc
fetch "${TARBALL}"

echo
echo ">> verifying before this is allowed anywhere near a build"
"${REPO_ROOT}/scripts/verify.sh" "${VERSION}" "${TRIPLE}"

cat <<EOF

Done. Next steps:
  1. Read scripts/verify.sh output above. Confirm the signer fingerprints are
     ones you have independently seen before (guix.sigs history, prior
     releases, out-of-band sources). A brand new fingerprint is a question,
     not a formality.
  2. git add vendor/ && git commit
  3. make build VERSION=${VERSION}
EOF
