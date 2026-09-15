#!/usr/bin/env bash
#
# Verify that an image's signature AND all three attestations round-trip.
#
# WHY ALL THREE: until 2026-09-15 this checked only the provenance attestation,
# while `attest` attached three. The contents manifest — the one guarantee this
# repo makes that is hard to get elsewhere — had no verification path at all. A
# signing pipeline nobody verifies end to end is the same decoration problem as
# an untested gate.
#
# Key-pair signatures here are deliberately not in Rekor (see sign-image.sh), so
# verification passes --insecure-ignore-tlog. That warning is about the absence
# of a transparency log, not about the signature itself. The keyless mode is what
# provides the transparency trail.
#
#   usage: scripts/verify-signatures.sh <image-ref>
#
# env:
#   COSIGN_PUB=        path to the cosign public key — verifies the key-pair mode
#   COSIGN_IDENTITY=   expected certificate identity regexp — verifies keyless
#   COSIGN_ISSUER=     expected OIDC issuer (default: GitHub Actions)
#   COSIGN_EXTRA=      extra cosign flags, e.g. --allow-insecure-registry
#
set -euo pipefail

IMAGE_REF="${1:?usage: verify-signatures.sh <image-ref>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PRED_PROVENANCE="${PRED_PROVENANCE:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-provenance/v1}"
PRED_CONTENTS="${PRED_CONTENTS:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"
read -r -a EXTRA <<< "${COSIGN_EXTRA:-}"

command -v cosign >/dev/null || { echo "cosign not found" >&2; exit 1; }

key_mode=0; keyless_mode=0
[[ -n "${COSIGN_PUB:-}" ]] && key_mode=1
[[ -n "${COSIGN_IDENTITY:-}" ]] && keyless_mode=1
if (( ! key_mode && ! keyless_mode )); then
  echo "nothing to verify: set COSIGN_PUB, COSIGN_IDENTITY, or both" >&2; exit 1
fi

digest="$(docker buildx imagetools inspect "${IMAGE_REF}" --format '{{.Manifest.Digest}}' 2>/dev/null)" \
  || { echo "cannot resolve ${IMAGE_REF}" >&2; exit 1; }
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
echo ">> ${REF}"
echo

fail=0
check() { # <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  OK    %s\n' "${label}"
  else printf '  FAIL  %s\n' "${label}"; fail=1; fi
}

if (( key_mode )); then
  echo "key-pair mode (offline, ${COSIGN_PUB##*/}):"
  kv=(cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog "${EXTRA[@]}")
  ka=(cosign verify-attestation --key "${COSIGN_PUB}" --insecure-ignore-tlog "${EXTRA[@]}")
  check "signature"          "${kv[@]}" "${REF}"
  check "provenance"         "${ka[@]}" --type "${PRED_PROVENANCE}" "${REF}"
  check "sbom"               "${ka[@]}" --type spdxjson             "${REF}"
  check "contents manifest"  "${ka[@]}" --type "${PRED_CONTENTS}"   "${REF}"
  echo
fi

if (( keyless_mode )); then
  # A value starting with ^ is a regexp; anything else is an exact identity.
  # Passing an exact string to --certificate-identity-regexp would leave it
  # unanchored with '.' matching any character — harmless in practice, since the
  # OIDC provider controls the identity prefix, but exact is free and correct.
  if [[ "${COSIGN_IDENTITY}" == ^* ]]; then
    echo "keyless mode (identity matches ${COSIGN_IDENTITY}):"
    id=(--certificate-identity-regexp "${COSIGN_IDENTITY}")
  else
    echo "keyless mode (identity == ${COSIGN_IDENTITY}):"
    id=(--certificate-identity "${COSIGN_IDENTITY}")
  fi
  id+=(--certificate-oidc-issuer "${COSIGN_ISSUER}")
  check "signature"          cosign verify "${id[@]}" "${EXTRA[@]}" "${REF}"
  check "provenance"         cosign verify-attestation "${id[@]}" "${EXTRA[@]}" --type "${PRED_PROVENANCE}" "${REF}"
  check "sbom"               cosign verify-attestation "${id[@]}" "${EXTRA[@]}" --type spdxjson             "${REF}"
  check "contents manifest"  cosign verify-attestation "${id[@]}" "${EXTRA[@]}" --type "${PRED_CONTENTS}"   "${REF}"
  echo
fi

if (( fail )); then
  echo "FAIL — the signing chain does not round-trip" >&2
  exit 1
fi
echo "OK — signature and all three attestations verify"
