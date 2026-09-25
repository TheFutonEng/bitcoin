#!/usr/bin/env bash
#
# List the platform images inside a published OCI index, one per line:
#
#   linux/amd64 sha256:...
#   linux/arm64 sha256:...
#
# buildkit also puts its provenance and SBOM manifests in the index, with
# platform unknown/unknown; those are not images and are left out. The digests
# printed are the per-platform IMAGE MANIFESTS, which is what this repo attaches
# its attestations to and what the reproducibility claim is about — not the
# index digest, which consumers pin but which is deliberately not reproducible.
#
# Reads the registry, never the local image store: `imagetools inspect` has no
# local mode. That is the property the release relies on to verify what was
# actually published rather than what happens to be tagged locally.
#
#   usage: scripts/list-platforms.sh <image-ref>
#
set -euo pipefail

REF="${1:?usage: list-platforms.sh <image-ref>}"
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

raw="$(docker buildx imagetools inspect --raw "${REF}")" \
  || { echo "cannot read ${REF} from the registry" >&2; exit 1; }

out="$(jq -r '
  if (.manifests | type) != "array" then error("not an index")
  else .manifests[]
       | select(.platform.os != "unknown")
       | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end) \(.digest)"
  end' <<<"${raw}" 2>/dev/null)" || {
  echo "${REF} is not an OCI index — every image this repo publishes is one" >&2
  exit 1
}
[[ -n "${out}" ]] || { echo "${REF} contains no platform images" >&2; exit 1; }
printf '%s\n' "${out}"
