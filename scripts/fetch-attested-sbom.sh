#!/usr/bin/env bash
#
# Fetch the SBOM a release ATTESTED to one platform image — verified first.
#
# The scheduled rescan scans this, not a freshly generated SBOM, for two
# reasons. It is exactly the package list the release signed, so a finding is
# tied to signed evidence about these bytes rather than to whatever today's
# syft happens to inventory. And every rescan re-verifies the attestation, so a
# signature that stops verifying is noticed the same day.
#
# Keyless only, against the EXACT identity of the release workflow on this tag:
# a signature from the same workflow on a different tag, or from any other
# workflow, does not count. The key-pair attestations are not needed here and
# are checked by `make verify-sig`.
#
#   usage: scripts/fetch-attested-sbom.sh <image@sha256:platform-digest> <tag> <out.spdx.json>
#          tag is <version>-<revision>, e.g. 31.1-4 (the git tag is v<tag>)
#
# env:
#   SOURCE_REPO=    default https://github.com/TheFutonEng/bitcoin
#   COSIGN_ISSUER=  default https://token.actions.githubusercontent.com
#
set -euo pipefail

REF="${1:?usage: fetch-attested-sbom.sh <image@digest> <tag> <out.spdx.json>}"
TAG="${2:?usage: fetch-attested-sbom.sh <image@digest> <tag> <out.spdx.json>}"
OUT="${3:?usage: fetch-attested-sbom.sh <image@digest> <tag> <out.spdx.json>}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/TheFutonEng/bitcoin}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"

for t in cosign jq; do
  command -v "${t}" >/dev/null || { echo "${t} not found" >&2; exit 1; }
done
[[ "${REF}" == *@sha256:* ]] || { echo "fetch by platform digest, not by tag: ${REF}" >&2; exit 1; }
[[ "${TAG}" =~ ^[0-9]+(\.[0-9]+)+-[0-9]+$ ]] || { echo "tag '${TAG}' is not <version>-<revision>" >&2; exit 1; }

identity="${SOURCE_REPO}/.github/workflows/release.yml@refs/tags/v${TAG}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if ! cosign verify-attestation --type spdxjson \
     --certificate-identity "${identity}" --certificate-oidc-issuer "${COSIGN_ISSUER}" \
     "${REF}" > "${tmp}/att.jsonl" 2> "${tmp}/err"; then
  echo "FATAL: no SBOM attestation on ${REF} verifies as ${identity}" >&2
  sed 's/^/  /' "${tmp}/err" >&2
  exit 1
fi

# One line per verified attestation. A re-run release can attest twice; that is
# fine if both say the same thing, and ambiguous if they do not — refuse then,
# rather than pick one.
jq -c '.payload | @base64d | fromjson
       | select(.predicateType == "https://spdx.dev/Document") | .predicate' \
  "${tmp}/att.jsonl" | sort -u > "${tmp}/sboms.jsonl"
n="$(grep -c . "${tmp}/sboms.jsonl" || true)"
if [[ "${n}" != 1 ]]; then
  echo "FATAL: expected exactly one distinct SBOM attested to ${REF}, found ${n}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")"
jq . "${tmp}/sboms.jsonl" > "${OUT}"
echo "OK — SBOM attested to ${REF##*@} verified as ${identity}: ${OUT}"
