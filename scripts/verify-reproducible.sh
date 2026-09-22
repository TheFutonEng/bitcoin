#!/usr/bin/env bash
#
# Prove that building this commit produces the same image bytes everywhere.
#
# This is the strongest claim available to this repo and one `bitcoin/bitcoin`
# does not make: two people who have never met, on different machines, building
# the same commit, get the same image digest. It is worth more than any
# signature, because a signature says "I built this" while a reproducible digest
# says "and you would have got the same thing".
#
# WHAT IS REPRODUCIBLE, AND WHAT IS NOT. Measured 2026-09-21, not assumed.
#
#   The IMAGE MANIFEST digest is reproducible. Verified identical across two
#   buildkit versions (v0.29.0 embedded, v0.32.2 in a docker-container builder),
#   two drivers, cached and --no-cache, and via both an OCI export and a real
#   registry push.
#
#   The OCI INDEX digest is NOT, and cannot be made so. The index wraps the
#   image manifest together with the attestation manifest, and the attestations
#   contain irreducibly per-build values: buildkit stamps `startedOn`,
#   `finishedOn` and a random `invocationId` into the SLSA provenance, and syft
#   stamps a `created` time and a random UUID `documentNamespace` into the SBOM.
#   Two builds of the same commit differ there every time.
#
#   That matters because the index digest is what consumers pin. So the claim
#   this script supports is precisely: **the image inside the published index is
#   reproducible**, not "the published digest is reproducible". Do not let the
#   docs blur those two. `--against` exists to check exactly the former against
#   a real published artifact.
#
# WHY A CANONICAL BUILD. The digest depends on VCS_REF and BUILD_DATE, which
# change with every commit, so an expected digest for the current commit can
# never be committed alongside it — the file would have to contain a hash of
# itself. The default mode therefore builds with FIXED placeholder values, which
# makes the digest a function of the things that actually matter: the Dockerfile,
# the verified tarball, the accepted signer list baked into the breadcrumbs, and
# the pinned base image. That digest lives in reproducible-digest.txt and CI
# compares against it on every PR — so the check runs on a machine that is not
# the one that produced the value, which is the whole point.
#
# Determinism with real build args follows from determinism with canonical ones:
# the args only ever reach the image as label strings, and they are themselves
# derived from the commit (see the VCS_REF and SOURCE_REPO notes in the
# Makefile, both of which were environment-dependent bugs).
#
#   usage:
#     scripts/verify-reproducible.sh                 # canonical build vs the committed digest
#     scripts/verify-reproducible.sh --write         # update that file (a reviewed commit)
#     scripts/verify-reproducible.sh --release       # print the digest for THIS commit
#     scripts/verify-reproducible.sh --against REF   # compare THIS commit to a published image
#
set -euo pipefail

VERSION="${VERSION:-31.1}"
TRIPLE="${TRIPLE:-x86_64-linux-gnu}"
PLATFORM="${PLATFORM:-linux/amd64}"
MIN_GOOD_SIGS="${MIN_GOOD_SIGS:-6}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_FILE="${REPO_ROOT}/reproducible-digest.txt"

mode="compare"
against=""
case "${1:-}" in
  "")         mode="compare" ;;
  --write)    mode="write" ;;
  --release)  mode="release" ;;
  --against)  mode="against"; against="${2:?--against needs an image reference}" ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# The Makefile is the single source for these; check-pins.sh asserts the
# Dockerfile agrees. Read rather than duplicate.
RUNTIME_BASE="$(sed -n 's/^RUNTIME_BASE[[:space:]]*?*=[[:space:]]*\(.*\)$/\1/p' "${REPO_ROOT}/Makefile" | head -1)"
[[ -n "${RUNTIME_BASE}" ]] || { echo "could not read RUNTIME_BASE from Makefile" >&2; exit 1; }

if [[ "${mode}" == "compare" || "${mode}" == "write" ]]; then
  # Canonical placeholders. Changing any of these changes every expected digest,
  # so they are constants, not defaults to be overridden.
  vcs_ref="000000000000"
  build_date="1970-01-01T00:00:00Z"
  source_repo="https://github.com/TheFutonEng/bitcoin"
  epoch=0
  label="canonical"
else
  vcs_ref="$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD)"
  epoch="$(git -C "${REPO_ROOT}" log -1 --pretty=%ct)"
  build_date="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ)"
  source_repo="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
                 | sed -e 's#^git@\([^:]*\):#https://\1/#' -e 's#\.git$##')"
  label="commit ${vcs_ref}"
fi

TARBALL="${REPO_ROOT}/upstream/bitcoin-${VERSION}-${TRIPLE}.tar.gz"
[[ -f "${TARBALL}" ]] || {
  echo "missing upstream/$(basename "${TARBALL}")" >&2
  echo "run: make fetch-tarball VERSION=${VERSION}" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# SOURCE_DATE_EPOCH must be EXPORTED, not merely computed. buildkit reads it
# from the environment and forwards it as a build arg; `rewrite-timestamp=true`
# then rewrites layer mtimes to it. Missing the export does not fail the build —
# it silently produces a different, though still stable, digest, which is the
# worst of both worlds: the check keeps passing locally and disagrees with every
# other caller. The Makefile exports it for the same reason.
export SOURCE_DATE_EPOCH="${epoch}"

echo "building ${label} — platform ${PLATFORM}, source-date-epoch ${epoch}"

# Deliberately NOT --load and NOT --push.
#
# `rewrite-timestamp=true` is the flag that makes any of this work: without it
# every file in the layers we add carries the wall-clock time of the build, so
# two builds of the same commit differ in the layer tars and therefore in every
# digest above them. SOURCE_DATE_EPOCH alone does not do it — buildkit applies
# that to the image config, not to the layer contents. Measured: without this
# flag two builds minutes apart produced different manifests whose only
# difference was mtimes.
#
# It also conflicts with `unpack`, which the containerd image store turns on for
# --load and for type=image. An OCI layout export never unpacks, so this path
# works the same on a laptop with the containerd store and on a runner without
# it — the environment difference that has broken this repo's build tooling
# twice already.
#
# Attestations are off on purpose: they are what makes the index digest vary,
# and they do not affect the image manifest. Verified — the same manifest digest
# comes out with them attached and without.
docker buildx build \
  --platform "${PLATFORM}" \
  --network=none \
  --build-arg BITCOIN_VERSION="${VERSION}" \
  --build-arg TARGET_TRIPLE="${TRIPLE}" \
  --build-arg RUNTIME_BASE="${RUNTIME_BASE}" \
  --build-arg MIN_GOOD_SIGS="${MIN_GOOD_SIGS}" \
  --build-arg SOURCE_REPO="${source_repo}" \
  --build-arg VCS_REF="${vcs_ref}" \
  --build-arg BUILD_DATE="${build_date}" \
  --provenance=false --sbom=false \
  --metadata-file "${WORK}/meta.json" \
  --output "type=oci,dest=${WORK}/oci,tar=false,rewrite-timestamp=true" \
  "${REPO_ROOT}" >"${WORK}/build.log" 2>&1 || {
    echo "build failed:" >&2; tail -25 "${WORK}/build.log" >&2; exit 1;
  }

# With attestations off and an OCI layout output, containerimage.digest IS the
# image manifest digest. With attestations on it would be the index digest —
# which is exactly the value that is not reproducible.
digest="$(sed -n 's/.*"containerimage.digest": *"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "${WORK}/meta.json" | head -1)"
[[ -n "${digest}" ]] || { echo "could not read containerimage.digest from build metadata" >&2; exit 1; }

echo "image manifest digest: ${digest}"

case "${mode}" in
  release)
    exit 0
    ;;

  write)
    cat > "${EXPECTED_FILE}" <<EOF
# Reproducible image manifest digest for a CANONICAL build of this tree.
#
# Regenerate with:  make repro-digest-write
# Verified by:      make verify-repro   (runs in CI on every pull request)
#
# This is NOT the digest consumers pin. Consumers pin the published OCI index,
# which also contains attestations and is deliberately not reproducible — see
# the header of scripts/verify-reproducible.sh. This is the digest of the image
# INSIDE that index, built with placeholder VCS_REF/BUILD_DATE so the value does
# not change on every commit.
#
# It changes when the Dockerfile, the verified tarball, the accepted signer list
# or the pinned base image changes. Any other change to it is a reproducibility
# regression, and CI is what says so.
#
# version:  ${VERSION}
# triple:   ${TRIPLE}
# platform: ${PLATFORM}
${digest}
EOF
    echo "wrote ${EXPECTED_FILE#"${REPO_ROOT}/"}"
    ;;

  compare)
    [[ -f "${EXPECTED_FILE}" ]] || {
      echo "FATAL: ${EXPECTED_FILE#"${REPO_ROOT}/"} does not exist" >&2
      echo "       create it with: make repro-digest-write" >&2
      exit 1
    }
    expected="$(grep -oE '^sha256:[0-9a-f]{64}$' "${EXPECTED_FILE}" | head -1)"
    [[ -n "${expected}" ]] || { echo "no digest found in ${EXPECTED_FILE}" >&2; exit 1; }
    echo "expected             : ${expected}"
    if [[ "${digest}" == "${expected}" ]]; then
      echo
      echo "OK — this build is bit-for-bit what the committed digest describes"
    else
      echo >&2
      echo "FATAL: reproducibility regression" >&2
      echo "  expected ${expected}" >&2
      echo "  got      ${digest}" >&2
      echo >&2
      echo "If you changed the Dockerfile, the vendored release, the allowlist or" >&2
      echo "the pinned base image, this is expected: run 'make repro-digest-write'" >&2
      echo "and commit the new value as a reviewed change. If you changed NONE of" >&2
      echo "those, the build has stopped being reproducible and that is the bug." >&2
      exit 1
    fi
    ;;

  against)
    # The consumer-facing check: does the image inside a PUBLISHED index match
    # what this commit builds? Attestation manifests carry platform
    # unknown/unknown, which is how they are told apart from the real image.
    echo "published reference  : ${against}"
    published="$(docker buildx imagetools inspect "${against}" --format \
      '{{range .Manifest.Manifests}}{{if ne .Platform.OS "unknown"}}{{.Digest}}{{end}}{{end}}' 2>/dev/null)"
    [[ -n "${published}" ]] || {
      echo "could not read an image manifest out of ${against}" >&2; exit 1; }
    echo "published image      : ${published}"
    if [[ "${digest}" == "${published}" ]]; then
      echo
      echo "OK — the published image is bit-for-bit this commit"
    else
      echo >&2
      echo "FATAL: the published image is NOT what this commit builds" >&2
      echo "  this commit builds ${digest}" >&2
      echo "  published image is ${published}" >&2
      echo >&2
      echo "Check you are on the tagged commit for that image. Releases before" >&2
      echo "the reproducibility work landed were built without rewrite-timestamp" >&2
      echo "and carry wall-clock file mtimes, so they can never match." >&2
      exit 1
    fi
    ;;
esac
