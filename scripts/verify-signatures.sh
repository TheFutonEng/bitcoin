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
# MULTI-ARCH, from 31.1-3: the index is signed, every image in it is signed,
# and each image carries its own three attestations — see sign-image.sh. Each
# attestation is also checked to be ABOUT the image it is attached to: the
# contents manifest must name that digest, the SBOM must describe it, and the
# provenance must be for the same tarball triple. A valid signature over the
# wrong platform's evidence is otherwise indistinguishable from the right one.
#
#   usage: scripts/verify-signatures.sh <image-ref>
#
# env:
#   COSIGN_PUB=        path to the cosign public key — verifies the key-pair mode
#   COSIGN_IDENTITY=   expected certificate identity regexp — verifies keyless
#   COSIGN_ISSUER=     expected OIDC issuer (default: GitHub Actions)
#   COSIGN_EXTRA=      extra cosign flags, e.g. --allow-insecure-registry
#   ATTESTATIONS_ON=   `platform` (default) for 31.1-3 onward; `index` for
#                      releases up to 31.1-1, which attached their attestations
#                      to the index digest. (31.1-2 carries no signatures at all:
#                      its release failed after the push — see CLAUDE.md.) Explicit rather than guessed: a
#                      verifier that falls back to the older layout when the
#                      newer one is missing would accept an image stripped of
#                      its per-platform attestations.
#
set -euo pipefail

IMAGE_REF="${1:?usage: verify-signatures.sh <image-ref>}"

PRED_PROVENANCE="${PRED_PROVENANCE:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-provenance/v1}"
PRED_CONTENTS="${PRED_CONTENTS:-https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1}"
COSIGN_ISSUER="${COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"
read -r -a EXTRA <<< "${COSIGN_EXTRA:-}"
ATTESTATIONS_ON="${ATTESTATIONS_ON:-platform}"
[[ "${ATTESTATIONS_ON}" == platform || "${ATTESTATIONS_ON}" == index ]] \
  || { echo "ATTESTATIONS_ON must be 'platform' or 'index'" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v cosign >/dev/null || { echo "cosign not found" >&2; exit 1; }
command -v jq     >/dev/null || { echo "jq not found" >&2; exit 1; }

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

# Which digests carry the attestations, and which platform each one is.
targets=(); labels=()
if [[ "${ATTESTATIONS_ON}" == index ]]; then
  targets=("${REF}"); labels=("index")
else
  # Captured, not `< <(...)`: a failed read must fail here, not yield an empty
  # list that verifies nothing and reports success.
  listing="$("${REPO_ROOT}/scripts/list-platforms.sh" "${REF}")"
  while read -r plat pdigest; do
    targets+=("${base}@${pdigest}"); labels+=("${plat}")
  done <<<"${listing}"
fi
(( ${#targets[@]} > 0 )) || { echo "FATAL: nothing to verify in ${REF}" >&2; exit 1; }

fail=0
check() { # <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  OK    %s\n' "${label}"
  else printf '  FAIL  %s\n' "${label}"; fail=1; fi
}

# <label> <target> <verify-attestation argv...> — verifies all three
# attestations on one image and, in the per-platform layout, that each is about
# that image. Every matching attestation must pass, not just one: a digest can
# carry several of one type, and a stale or foreign one among them is exactly
# what this is looking for.
check_attestations() {
  local label="$1" target="$2"; shift 2
  local va=("$@") vs=("${@/verify-attestation/verify}") pdigest="${target##*@}" out ok triples
  # The index signature is checked once by verify_mode; in the index layout the
  # target IS the index, so checking it again here would only print it twice.
  [[ "${target}" == "${REF}" ]] || check "${label}: signature" "${vs[@]}" "${target}"

  local -A payload=()
  local t
  for t in provenance sbom contents; do
    local type
    case "${t}" in
      provenance) type="${PRED_PROVENANCE}" ;;
      sbom)       type=spdxjson ;;
      contents)   type="${PRED_CONTENTS}" ;;
    esac
    if out="$("${va[@]}" --type "${type}" "${target}" 2>/dev/null)" && [[ -n "${out}" ]]; then
      payload[${t}]="$(jq -c '.payload | @base64d | fromjson | .predicate' <<<"${out}")"
      printf '  OK    %s: %s\n' "${label}" "${t}"
    else
      printf '  FAIL  %s: %s\n' "${label}" "${t}"; fail=1
    fi
  done

  [[ "${ATTESTATIONS_ON}" == platform ]] || return 0
  # A missing attestation has already failed above; saying it "describes a
  # different image" as well would point at the wrong problem.
  [[ -n "${payload[provenance]:-}" && -n "${payload[sbom]:-}" && -n "${payload[contents]:-}" ]] || return 0
  ok=1
  jq -se --arg d "${pdigest}" 'length > 0 and all(.[]; .image | endswith("@" + $d))' \
    <<<"${payload[contents]:-}" >/dev/null || ok=0
  jq -se --arg d "${pdigest}" 'length > 0 and all(.[]; any(.packages[]; .versionInfo == $d))' \
    <<<"${payload[sbom]:-}" >/dev/null || ok=0
  triples="$(jq -r .triple <<<"${payload[provenance]:-}${payload[contents]:-}" 2>/dev/null | sort -u)"
  [[ -n "${triples}" && "$(grep -c . <<<"${triples}")" == 1 ]] || ok=0
  if (( ok )); then printf '  OK    %s: attestations describe this image (%s)\n' "${label}" "${triples}"
  else printf '  FAIL  %s: an attestation describes a DIFFERENT image\n' "${label}"; fail=1; fi
}

verify_mode() { # <cosign verify-attestation argv...>
  local va=("$@") vs=("${@/verify-attestation/verify}") i
  check "index: signature" "${vs[@]}" "${REF}"
  for i in "${!targets[@]}"; do
    check_attestations "${labels[$i]}" "${targets[$i]}" "${va[@]}"
  done
}

if (( key_mode )); then
  echo "key-pair mode (offline, ${COSIGN_PUB##*/}):"
  verify_mode cosign verify-attestation --key "${COSIGN_PUB}" --insecure-ignore-tlog "${EXTRA[@]}"
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
  verify_mode cosign verify-attestation "${id[@]}" "${EXTRA[@]}"
  echo
fi

if (( fail )); then
  echo "FAIL — the signing chain does not round-trip" >&2
  exit 1
fi
echo "OK — signatures and all attestations verify, for ${#targets[@]} image(s)"
