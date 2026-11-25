#!/usr/bin/env bash
#
# Install the two vulnerability scanners, pinned by version AND by hash.
#
# Two scanners on purpose. On the first scan of 31.1-3 they reported the same
# eight CVEs and disagreed completely on how bad they were — Grype said two
# Critical, Trivy said none — because Debian had not rated them and each fell
# back to a different source. One scanner alone gives a confident, arbitrary
# answer. scripts/scan-image.sh runs both and reports where they differ.
#
# The hashes below were not copied from a web page. Each vendor publishes a
# checksums file signed with cosign by its release workflow; the file's
# signature was verified against that identity, and the tarball hashes were
# taken from the verified file. `--verify-pins` repeats exactly that, so a pin
# bump is a procedure rather than an act of trust:
#
#   scripts/install-scanners.sh --verify-pins    # needs cosign and network
#
# Identities, both exact rather than a loose pattern:
#   grype  .../anchore/grype/.github/workflows/release.yaml@refs/heads/main
#          (Anchore releases by dispatching that workflow on main, not on a tag)
#   trivy  .../aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v<version>
#
#   usage: scripts/install-scanners.sh [--verify-pins]
#
# env:
#   SCANNER_BIN=   install directory (default: <repo>/.tools/bin, gitignored)
#
set -euo pipefail

GRYPE_VERSION=0.119.0
TRIVY_VERSION=0.74.0
declare -A PIN=(
  [grype_amd64]=3fa2dc4b924621ab65404cf08d0b8438d896d80ab949c9d5a4ca283c36004c9b
  [grype_arm64]=29f0ec7c549ddb0e2b6a0ca714851f7399438afc399b80c12808e065edc9a8f8
  [trivy_amd64]=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a
  [trivy_arm64]=b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER_BIN="${SCANNER_BIN:-${REPO_ROOT}/.tools/bin}"
GH=https://github.com
OIDC=https://token.actions.githubusercontent.com

# Vendor asset names differ: Grype says amd64/arm64, Trivy says 64bit/ARM64.
grype_asset() { echo "grype_${GRYPE_VERSION}_linux_${1}.tar.gz"; }
trivy_asset() { case "$1" in amd64) echo "trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" ;;
                             arm64) echo "trivy_${TRIVY_VERSION}_Linux-ARM64.tar.gz" ;; esac; }
grype_url()   { echo "${GH}/anchore/grype/releases/download/v${GRYPE_VERSION}/$1"; }
trivy_url()   { echo "${GH}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/$1"; }
fetch()       { curl -sSfL --proto '=https' --tlsv1.2 -o "$2" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if [[ "${1:-}" == "--verify-pins" ]]; then
  command -v cosign >/dev/null || { echo "--verify-pins needs cosign" >&2; exit 1; }
  fail=0
  gsums="grype_${GRYPE_VERSION}_checksums.txt"; tsums="trivy_${TRIVY_VERSION}_checksums.txt"
  for f in "${gsums}" "${gsums}.pem" "${gsums}.sig"; do fetch "$(grype_url "$f")" "${tmp}/$f"; done
  for f in "${tsums}" "${tsums}.sigstore.json"; do fetch "$(trivy_url "$f")" "${tmp}/$f"; done

  if cosign verify-blob "${tmp}/${gsums}" \
       --certificate "${tmp}/${gsums}.pem" --signature "${tmp}/${gsums}.sig" \
       --certificate-identity "${GH}/anchore/grype/.github/workflows/release.yaml@refs/heads/main" \
       --certificate-oidc-issuer "${OIDC}" >/dev/null 2>&1; then
    echo "OK    grype ${GRYPE_VERSION} checksums: signature verified"
  else
    echo "FAIL  grype ${GRYPE_VERSION} checksums: signature does NOT verify"; fail=1
  fi
  if cosign verify-blob "${tmp}/${tsums}" --bundle "${tmp}/${tsums}.sigstore.json" \
       --certificate-identity "${GH}/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v${TRIVY_VERSION}" \
       --certificate-oidc-issuer "${OIDC}" >/dev/null 2>&1; then
    echo "OK    trivy ${TRIVY_VERSION} checksums: signature verified"
  else
    echo "FAIL  trivy ${TRIVY_VERSION} checksums: signature does NOT verify"; fail=1
  fi

  for arch in amd64 arm64; do
    for tool in grype trivy; do
      asset="$("${tool}_asset" "${arch}")"; sums="${tmp}/${tool}_$([[ ${tool} == grype ]] && echo "${GRYPE_VERSION}" || echo "${TRIVY_VERSION}")_checksums.txt"
      pinned="${PIN[${tool}_${arch}]}"
      signed="$(awk -v a="${asset}" '$2 == a { print $1 }' "${sums}")"
      if [[ -n "${signed}" && "${signed}" == "${pinned}" ]]; then
        printf 'OK    %-6s %-5s pinned hash matches the signed checksums\n' "${tool}" "${arch}"
      else
        printf 'FAIL  %-6s %-5s pinned %s, signed checksums say %s\n' "${tool}" "${arch}" "${pinned}" "${signed:-nothing}"
        fail=1
      fi
    done
  done
  (( fail == 0 )) || { echo "FAIL — do not use these pins" >&2; exit 1; }
  echo "OK — every pinned hash comes from a vendor-signed checksums file"
  exit 0
fi

case "$(uname -m)" in
  x86_64)        arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "no scanner pins for $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "${SCANNER_BIN}"
install_tool() { # <tool> <version>
  local tool="$1" version="$2" asset url pinned have
  # Already installed at the pinned version: nothing to do. Re-downloading on
  # every run costs time and would make a runner's scan depend on GitHub's
  # release CDN one more time than necessary.
  if [[ -x "${SCANNER_BIN}/${tool}" ]]; then
    have="$("${SCANNER_BIN}/${tool}" version 2>/dev/null | awk '/^Version:/ { print $2; exit }')"
    [[ "${have#v}" == "${version}" ]] && { echo "${tool} ${version} already installed"; return; }
  fi
  asset="$("${tool}_asset" "${arch}")"; url="$("${tool}_url" "${asset}")"
  pinned="${PIN[${tool}_${arch}]}"
  fetch "${url}" "${tmp}/${asset}"
  echo "${pinned}  ${tmp}/${asset}" | sha256sum -c --quiet - \
    || { echo "FAIL: ${asset} does not match its pinned hash" >&2; exit 1; }
  tar -xzf "${tmp}/${asset}" -C "${tmp}" "${tool}"
  install -m 0755 "${tmp}/${tool}" "${SCANNER_BIN}/${tool}"
  echo "${tool} ${version} installed (${arch}, sha256 ${pinned:0:12}…)"
}
install_tool grype "${GRYPE_VERSION}"
install_tool trivy "${TRIVY_VERSION}"
