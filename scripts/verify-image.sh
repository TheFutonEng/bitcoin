#!/usr/bin/env bash
#
# Independently verify that the binaries inside a container image are byte-for-byte
# the ones from the signature-verified upstream release tarball in upstream/.
#
# This works on ANY bitcoind image, not just ours. That is the point:
#
#   scripts/verify-image.sh ghcr.io/thefutoneng/bitcoin:31.1               # our output
#   scripts/verify-image.sh bitcoin/bitcoin:31.1                          # theirs
#
# Note what this does and does not prove. It proves the binaries are the correct
# upstream bytes, which is the part that actually executes your money. It says
# nothing about the rest of the image — base layer contents, extra files, config.
# For a third-party image that is most of the assurance you would want; for our
# own image it is a regression test on the build.
#
# SHA256SUMS lists tarball hashes, not per-binary hashes, so the comparison is
# against binaries extracted from the verified tarball rather than against
# SHA256SUMS directly. Run scripts/verify.sh first — this script assumes the
# staged tarball has already cleared the signature threshold.
#
#   usage: scripts/verify-image.sh <image-ref> [version] [triple]
#
set -euo pipefail

IMAGE="${1:?usage: verify-image.sh <image-ref> [version] [triple]}"
VERSION="${2:-31.1}"
TRIPLE="${3:-x86_64-linux-gnu}"
BIN_PATH="${BIN_PATH:-/usr/local/bin}"
BINARIES="${BINARIES:-bitcoind bitcoin-cli}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="${REPO_ROOT}/upstream/bitcoin-${VERSION}-${TRIPLE}.tar.gz"
[[ -f "${TARBALL}" ]] || { echo "missing ${TARBALL} — run scripts/fetch-release.sh first" >&2; exit 1; }

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; [[ -n "${cid:-}" ]] && docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ">> extracting reference binaries from verified tarball"
mkdir -p "${tmp}/ref"
tar -xzf "${TARBALL}" --strip-components=1 -C "${tmp}/ref"

echo ">> extracting binaries from ${IMAGE}"
mkdir -p "${tmp}/img"
# The image may have no shell, so copy out of a created-but-never-started container.
cid="$(docker create "${IMAGE}")"
for b in ${BINARIES}; do
  docker cp "${cid}:${BIN_PATH}/${b}" "${tmp}/img/${b}" 2>/dev/null \
    || { echo "  could not read ${BIN_PATH}/${b} from image — set BIN_PATH=" >&2; exit 1; }
done

echo
fail=0
for b in ${BINARIES}; do
  ref="$(sha256sum "${tmp}/ref/bin/${b}" | cut -d' ' -f1)"
  img="$(sha256sum "${tmp}/img/${b}"     | cut -d' ' -f1)"
  if [[ "${ref}" == "${img}" ]]; then
    printf 'MATCH     %-14s %s\n' "${b}" "${ref}"
  else
    printf 'MISMATCH  %-14s\n  upstream: %s\n  image:    %s\n' "${b}" "${ref}" "${img}"
    fail=1
  fi
done

echo
if (( fail )); then
  echo "FAIL — image binaries do not match the verified upstream release" >&2
  exit 1
fi
echo "OK — all binaries match the signature-verified upstream release"
