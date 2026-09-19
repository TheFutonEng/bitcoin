#!/usr/bin/env bash
#
# Sign a pushed image and attach its three attestations.
#
# TWO SIGNING MODES, deliberately both:
#
#   keyless (OIDC)  The signing identity is the GitHub workflow that produced
#                   the image — a stronger provenance claim than a key file,
#                   because it binds the signature to a repo, ref and workflow
#                   rather than to whoever holds a secret. Recorded in the public
#                   Rekor transparency log. Only works where an OIDC token
#                   exists, i.e. in CI; it cannot be exercised from a laptop
#                   without an interactive browser flow.
#
#   key pair        Verifiable offline, with no dependency on Sigstore being
#                   reachable. This is the mode that survives an air gap, which
#                   is why the repo carries both. Deliberately does NOT upload to
#                   Rekor — that is the keyless mode's job — so verification uses
#                   --insecure-ignore-tlog. The warning cosign prints there is
#                   about the absence of transparency, not about the signature.
#
# THREE PREDICATES are attached, not one. `verify-image.sh` proves the binaries
# are the right bytes; the contents manifest proves nothing *else* is in the
# image, and that is the guarantee this repo exists to make. An image signed
# without it is missing the interesting part.
#
# cosign v3 note: `--tlog-upload=false` conflicts with the default signing-config
# and errors out unless `--use-signing-config=false` is also passed. Verified
# against cosign v3.1.3.
#
#   usage: scripts/sign-image.sh <image-ref>        # tag or digest
#
# env:
#   COSIGN_KEY=        path to a cosign private key — enables key-pair signing
#   COSIGN_PASSWORD=   password for it (may be empty)
#   COSIGN_KEYLESS=1   enables keyless signing (CI)
#   COSIGN_EXTRA=      extra cosign flags, e.g. --allow-insecure-registry
#
set -euo pipefail

IMAGE_REF="${1:?usage: sign-image.sh <image-ref>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PRED_PROVENANCE="${PRED_PROVENANCE:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-provenance/v1}"
PRED_CONTENTS="${PRED_CONTENTS:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1}"
read -r -a EXTRA <<< "${COSIGN_EXTRA:-}"

command -v cosign >/dev/null || { echo "cosign not found" >&2; exit 1; }

key_mode=0; keyless_mode=0
[[ -n "${COSIGN_KEY:-}" ]] && key_mode=1
[[ "${COSIGN_KEYLESS:-0}" == "1" ]] && keyless_mode=1
if (( ! key_mode && ! keyless_mode )); then
  echo "nothing to do: set COSIGN_KEY, COSIGN_KEYLESS=1, or both" >&2; exit 1
fi
(( ! key_mode )) || [[ -f "${COSIGN_KEY}" ]] || { echo "no such key: ${COSIGN_KEY}" >&2; exit 1; }

# Every predicate must exist. Signing an image while silently omitting the
# contents manifest would publish exactly the wrong impression.
for f in provenance.json sbom.spdx.json contents-manifest.json; do
  [[ -f "$f" ]] && continue
  {
    echo "missing ${f}"
    echo
    echo "All three predicates must be present; signing an image while silently"
    echo "omitting the contents manifest would publish the wrong impression."
    echo
    echo "If you are signing an image this machine just built:"
    echo "    make verify sbom verify-contents"
    echo
    echo "If you are signing an image that is ALREADY PUBLISHED — adding a"
    echo "key-pair signature to an existing release, say — do not regenerate"
    echo "blindly. Prefer the predicates that release actually attested, saved"
    echo "by the release workflow as the artifact release-<version>-predicates."
    echo "Using those keeps the key-pair attestations byte-identical to the"
    echo "keyless ones. Failing that, regenerate them against the PUBLISHED"
    echo "image rather than a fresh local build:"
    echo "    make fetch-tarball    VERSION=<version>   # gitignored, may be absent"
    echo "    make verify           VERSION=<version>"
    echo "    make verify-contents  IMAGE=<image> TAG=<tag>"
    echo "    make sbom             IMAGE=<image> TAG=<tag>"
  } >&2
  exit 1
done

# Resolve to a digest. Signing a tag signs a moving target; everything below
# must refer to the same immutable thing.
echo ">> resolving ${IMAGE_REF}"
digest="$(docker buildx imagetools inspect "${IMAGE_REF}" --format '{{.Manifest.Digest}}' 2>/dev/null)" \
  || { echo "cannot resolve ${IMAGE_REF} — is it pushed?" >&2; exit 1; }
# Strip the tag or digest to get the repository. A colon only separates a tag
# when it is in the LAST path component — "localhost:5000/x/y" is a registry
# port, not a tag, and "${ref%%:*}" would reduce it to "localhost".
if [[ "${IMAGE_REF}" == *@* ]]; then
  base="${IMAGE_REF%%@*}"
elif [[ "${IMAGE_REF##*/}" == *:* ]]; then
  base="${IMAGE_REF%:*}"
else
  base="${IMAGE_REF}"
fi
REF="${base}@${digest}"
echo "   ${REF}"

sign_key()    { COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign --key "${COSIGN_KEY}" \
                  --use-signing-config=false --tlog-upload=false --yes "${EXTRA[@]}" "$@"; }
attest_key()  { COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign attest --key "${COSIGN_KEY}" \
                  --use-signing-config=false --tlog-upload=false --yes "${EXTRA[@]}" "$@"; }

if (( key_mode )); then
  echo ">> key-pair signing (offline-verifiable, no transparency log)"
  sign_key "${REF}"
  attest_key --predicate provenance.json        --type "${PRED_PROVENANCE}" "${REF}"
  attest_key --predicate sbom.spdx.json         --type spdxjson             "${REF}"
  attest_key --predicate contents-manifest.json --type "${PRED_CONTENTS}"   "${REF}"
  echo "   signed + 3 attestations"
fi

if (( keyless_mode )); then
  echo ">> keyless signing (identity = this workflow; logged to Rekor)"
  cosign sign --yes "${EXTRA[@]}" "${REF}"
  cosign attest --yes "${EXTRA[@]}" --predicate provenance.json        --type "${PRED_PROVENANCE}" "${REF}"
  cosign attest --yes "${EXTRA[@]}" --predicate sbom.spdx.json         --type spdxjson             "${REF}"
  cosign attest --yes "${EXTRA[@]}" --predicate contents-manifest.json --type "${PRED_CONTENTS}"   "${REF}"
  echo "   signed + 3 attestations"
fi

echo
echo "OK — ${REF}"
echo "publish that digest; consumers pin it."
