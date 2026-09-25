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
# MULTI-ARCH LAYOUT, from 31.1-3. The index and every image in it are signed
# (`cosign sign --recursive`). Each platform's attestations go on THAT
# PLATFORM'S manifest digest, from predicates/<os>-<arch>/ — never on the
# index. cosign attaches an attestation to exactly one digest, and each
# platform's evidence describes different bytes; two contents manifests of the
# same type on one index would leave a consumer to work out which is which.
# Before signing anything, every predicate is checked to have been produced
# from the digest it is about to be attached to.
#
# Releases up to 31.1-1 attached their attestations to the index instead; see
# ATTESTATIONS_ON in verify-signatures.sh for checking those.
#
# cosign v3 note: `--tlog-upload=false` conflicts with the default signing-config
# and errors out unless `--use-signing-config=false` is also passed. Verified
# against cosign v3.1.3.
#
#   usage: scripts/sign-image.sh <image-ref>        # tag or digest of the INDEX
#
# env:
#   COSIGN_KEY=        path to a cosign private key — enables key-pair signing
#   COSIGN_PASSWORD=   password for that key. Leave it UNSET to be prompted;
#                      set it (even to empty) to pass it through non-interactively
#   COSIGN_KEYLESS=1   enables keyless signing (CI)
#   COSIGN_EXTRA=      extra cosign flags, e.g. --allow-insecure-registry
#   PREDICATES_ROOT=   where the per-platform predicate dirs live (default:
#                      <repo>/predicates), as written by `make verify-published`
#
set -euo pipefail

IMAGE_REF="${1:?usage: sign-image.sh <image-ref>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PRED_PROVENANCE="${PRED_PROVENANCE:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-provenance/v1}"
PRED_CONTENTS="${PRED_CONTENTS:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1}"
read -r -a EXTRA <<< "${COSIGN_EXTRA:-}"
PREDICATES_ROOT="${PREDICATES_ROOT:-${REPO_ROOT}/predicates}"

command -v cosign >/dev/null || { echo "cosign not found" >&2; exit 1; }
command -v jq     >/dev/null || { echo "jq not found" >&2; exit 1; }

key_mode=0; keyless_mode=0
[[ -n "${COSIGN_KEY:-}" ]] && key_mode=1
[[ "${COSIGN_KEYLESS:-0}" == "1" ]] && keyless_mode=1
if (( ! key_mode && ! keyless_mode )); then
  echo "nothing to do: set COSIGN_KEY, COSIGN_KEYLESS=1, or both" >&2; exit 1
fi
(( ! key_mode )) || [[ -f "${COSIGN_KEY}" ]] || { echo "no such key: ${COSIGN_KEY}" >&2; exit 1; }

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
echo "   index ${REF}"

# Every platform in the index, and the predicates for each. ALL of this is
# checked before the first signature is made: a release that signs amd64 and
# then fails on arm64 would publish a half-signed index.
#
# Captured into a variable, not read with `mapfile < <(...)`: a process
# substitution's exit status is discarded, so a failed registry read would
# yield zero platforms and this script would sign the index with no
# attestations at all, and exit 0.
listing="$("${REPO_ROOT}/scripts/list-platforms.sh" "${REF}")"
mapfile -t platforms <<<"${listing}"
refs=(); dirs=()
for line in "${platforms[@]}"; do
  plat="${line%% *}"; pdigest="${line##* }"
  # os/arch only: an index may add a variant (linux/arm64/v8) that the
  # predicate directory, named from PLATFORM, does not carry.
  osarch="$(cut -d/ -f1-2 <<<"${plat}")"
  dir="${PREDICATES_ROOT}/${osarch//\//-}"
  echo "   ${plat} ${base}@${pdigest}"

  for f in provenance.json sbom.spdx.json contents-manifest.json; do
    [[ -f "${dir}/${f}" ]] && continue
    {
      echo "missing ${dir#"${REPO_ROOT}/"}/${f}"
      echo
      echo "All three predicates must be present for every platform; signing an"
      echo "image while silently omitting the contents manifest would publish the"
      echo "wrong impression. They are produced from the PUSHED image, by digest:"
      echo "    make verify-published PLATFORM=${osarch} IMAGE=<image> TAG=<tag>"
      echo
      echo "For an image that is ALREADY PUBLISHED, prefer the predicates that"
      echo "release actually attested, saved by the release workflow as the"
      echo "artifact release-<tag>-predicates, so a key-pair attestation added"
      echo "later is byte-identical to the keyless one."
    } >&2
    exit 1
  done

  # Each predicate must have been produced from THIS digest. Without this, the
  # arm64 contents manifest could be attached to the amd64 image and every
  # cosign check would still pass — it verifies who signed, not what was said.
  cm="${dir}/contents-manifest.json"; sb="${dir}/sbom.spdx.json"; pv="${dir}/provenance.json"
  jq -e --arg d "${pdigest}" '.image | endswith("@" + $d)' "${cm}" >/dev/null || {
    echo "FATAL: ${cm#"${REPO_ROOT}/"} was not produced from ${pdigest}" >&2
    echo "       it describes $(jq -r .image "${cm}")" >&2; exit 1; }
  jq -e --arg d "${pdigest}" 'any(.packages[]; .versionInfo == $d)' "${sb}" >/dev/null || {
    echo "FATAL: ${sb#"${REPO_ROOT}/"} does not describe ${pdigest}" >&2; exit 1; }
  [[ "$(jq -r .triple "${pv}")" == "$(jq -r .triple "${cm}")" ]] || {
    echo "FATAL: ${pv#"${REPO_ROOT}/"} is for $(jq -r .triple "${pv}")," \
         "but the contents manifest is for $(jq -r .triple "${cm}")" >&2; exit 1; }

  refs+=("${base}@${pdigest}"); dirs+=("${dir}")
done
(( ${#refs[@]} > 0 )) || { echo "FATAL: no platform images to attest in ${REF}" >&2; exit 1; }

# Do NOT force COSIGN_PASSWORD into the environment when the caller did not set
# it. `${COSIGN_PASSWORD:-}` substitutes an empty string for an UNSET variable,
# which cosign reads as "the password is empty" — so it never prompts, and a
# password-protected key fails with a bare "decryption failed" having never
# asked. `${VAR+x}` distinguishes unset from set-but-empty, so an explicitly
# empty password still works for an unencrypted key, and an unset one lets
# cosign prompt interactively (or fail fast in CI, where there is no TTY).
# An ARRAY, not command substitution: a password containing a space or a glob
# character would be word-split by an unquoted $(...) and silently mangled.
PWENV=()
[[ -n "${COSIGN_PASSWORD+x}" ]] && PWENV=(env "COSIGN_PASSWORD=${COSIGN_PASSWORD}")

sign_key()    { "${PWENV[@]}" cosign sign --key "${COSIGN_KEY}" \
                  --use-signing-config=false --tlog-upload=false --yes "${EXTRA[@]}" "$@"; }
attest_key()  { "${PWENV[@]}" cosign attest --key "${COSIGN_KEY}" \
                  --use-signing-config=false --tlog-upload=false --yes "${EXTRA[@]}" "$@"; }

sign_keyless()   { cosign sign   --yes "${EXTRA[@]}" "$@"; }
attest_keyless() { cosign attest --yes "${EXTRA[@]}" "$@"; }

# <mode> — signs the index and its images, then attests each platform.
sign_all() {
  local sign="sign_$1" attest="attest_$1" i
  "${sign}" --recursive "${REF}"
  for i in "${!refs[@]}"; do
    "${attest}" --predicate "${dirs[$i]}/provenance.json"        --type "${PRED_PROVENANCE}" "${refs[$i]}"
    "${attest}" --predicate "${dirs[$i]}/sbom.spdx.json"         --type spdxjson             "${refs[$i]}"
    "${attest}" --predicate "${dirs[$i]}/contents-manifest.json" --type "${PRED_CONTENTS}"   "${refs[$i]}"
  done
  echo "   index + ${#refs[@]} image(s) signed; 3 attestations on each image"
}

if (( key_mode )); then
  echo ">> key-pair signing (offline-verifiable, no transparency log)"
  sign_all key
fi

if (( keyless_mode )); then
  echo ">> keyless signing (identity = this workflow; logged to Rekor)"
  sign_all keyless
fi

echo
echo "OK — ${REF}"
echo "publish that digest; consumers pin it."
