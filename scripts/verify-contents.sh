#!/usr/bin/env bash
#
# Prove that EVERY file in a container image is accounted for.
#
# scripts/verify-image.sh answers "are the binaries we ship the right bytes?".
# This script answers the harder question: "is there anything in this image that
# we cannot explain?" Those are different guarantees. An image can carry correct
# binaries and also carry an extra file nobody noticed; verify-image.sh passes
# that image, this one does not.
#
# The method is subtraction. Every regular file and symlink in the image rootfs
# must fall into exactly one bucket:
#
#   base       byte-identical to a file in the pinned base image
#   verified   byte-identical to a file from the signature-verified tarball
#   generated  a build-time provenance breadcrumb, allowlisted by path
#
# Anything left over is UNACCOUNTED and fails the run. A file whose path exists
# in the base but whose content differs is MODIFIED and also fails — that is the
# case where something was swapped underneath us.
#
# The base image is read from the image's own
# org.opencontainers.image.base.name label, so the image declares what it claims
# to be built on and this script holds it to that claim. Override with BASE=.
# Note the label is only as good as the pin behind it: while RUNTIME_BASE is a
# tag rather than a digest, "the base" is whatever that tag resolves to today.
#
#   usage: scripts/verify-contents.sh <image-ref> [version] [triple]
#
# env:
#   BASE=              override the base image ref (default: from the label)
#   SHIP_BINARIES=     binaries expected from the tarball (default: bitcoind bitcoin-cli)
#   UPSTREAM_DIR=      where the verified tarball lives (default: <repo>/upstream)
#   MANIFEST=          write the JSON manifest here (default: <repo>/contents-manifest.json)
#
set -euo pipefail

IMAGE="${1:?usage: verify-contents.sh <image-ref> [version] [triple]}"
VERSION="${2:-31.1}"
TRIPLE="${3:-x86_64-linux-gnu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${UPSTREAM_DIR:-${REPO_ROOT}/upstream}"
MANIFEST="${MANIFEST:-${REPO_ROOT}/contents-manifest.json}"
SHIP_BINARIES="${SHIP_BINARIES-bitcoind bitcoin-cli}"
TARBALL="${UPSTREAM_DIR}/bitcoin-${VERSION}-${TRIPLE}.tar.gz"

# Build-time breadcrumbs. Content is generated per build, so these are trusted by
# PATH, not by hash. Keep this list short and explicit — every entry here is a
# hole in the guarantee.
GENERATED_PATHS="
usr/local/share/bitcoind-provenance/accepted-signers.txt
usr/local/share/bitcoind-provenance/upstream-digest.txt
"

BASE="${BASE:-$(docker inspect --format \
  '{{index .Config.Labels "org.opencontainers.image.base.name"}}' \
  "${IMAGE}" 2>/dev/null || true)}"
[[ -n "${BASE}" ]] || {
  echo "cannot determine base image: no org.opencontainers.image.base.name label" >&2
  echo "on ${IMAGE}. Pass it explicitly with BASE=<ref>." >&2
  exit 1
}

tmp="$(mktemp -d)"
cids=()
cleanup() {
  rm -rf "${tmp}"
  for c in ${cids[@]+"${cids[@]}"}; do docker rm -f "${c}" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# Export an image's flat rootfs and emit "<sha256>  <path>" for every regular
# file, plus "symlink:<target>  <path>" for every symlink. Directories and
# special files are not content-bearing and are skipped.
inventory() {
  local image="$1" out="$2" dir="${tmp}/fs.$$.${RANDOM}"
  local cid
  # A dummy command keeps `docker create` happy on images with no CMD, such as
  # the distroless base. The container is never started.
  cid="$(docker create "${image}" /nonexistent-never-run 2>/dev/null)" || {
    echo "docker create failed for ${image}" >&2; return 1; }
  cids+=("${cid}")
  mkdir -p "${dir}"
  docker export "${cid}" | tar -x -C "${dir}" \
    --no-same-owner --no-same-permissions --delay-directory-restore 2>/dev/null || true
  docker rm -f "${cid}" >/dev/null 2>&1 || true

  ( cd "${dir}"
    find . -type f -printf '%P\0' 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
      printf '%s  %s\n' "$(sha256sum -- "$f" | cut -d' ' -f1)" "$f"
    done
    find . -type l -printf '%P\0' 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
      printf 'symlink:%s  %s\n' "$(readlink -- "$f")" "$f"
    done
  ) | sort -k2 > "${out}"
  rm -rf "${dir}"
}

echo ">> inventorying image:  ${IMAGE}"
inventory "${IMAGE}" "${tmp}/image.txt"
echo ">> inventorying base:   ${BASE}"
inventory "${BASE}" "${tmp}/base.txt"

# Expected files contributed by the verified release tarball, keyed by the path
# they occupy in the final image.
: > "${tmp}/ours.txt"
if [[ -n "${SHIP_BINARIES}" ]]; then
  [[ -f "${TARBALL}" ]] || {
    echo "missing ${TARBALL} — run scripts/fetch-release.sh first" >&2
    echo "(or set SHIP_BINARIES= to check an image that ships none)" >&2
    exit 1; }
  echo ">> extracting expected files from ${TARBALL##*/}"
  mkdir -p "${tmp}/ref"
  tar -xzf "${TARBALL}" --strip-components=1 -C "${tmp}/ref"
  for b in ${SHIP_BINARIES}; do
    [[ -f "${tmp}/ref/bin/${b}" ]] || { echo "tarball has no bin/${b}" >&2; exit 1; }
    printf '%s  usr/local/bin/%s\n' \
      "$(sha256sum "${tmp}/ref/bin/${b}" | cut -d' ' -f1)" "${b}" >> "${tmp}/ours.txt"
  done
  if [[ -d "${tmp}/ref/lib" ]]; then
    ( cd "${tmp}/ref/lib"
      find . -type f -printf '%P\0' | while IFS= read -r -d '' f; do
        printf '%s  usr/local/lib/%s\n' "$(sha256sum -- "$f" | cut -d' ' -f1)" "$f"
      done ) >> "${tmp}/ours.txt"
  fi
fi
sort -k2 -o "${tmp}/ours.txt" "${tmp}/ours.txt"

printf '%s\n' ${GENERATED_PATHS} | sed '/^$/d' | sort > "${tmp}/generated.txt"

# --- classify -------------------------------------------------------------
awk -v ours="${tmp}/ours.txt" -v base="${tmp}/base.txt" -v gen="${tmp}/generated.txt" '
BEGIN {
  while ((getline line < base) > 0)  { i=index(line,"  "); b[substr(line,i+2)]=substr(line,1,i-1) }
  while ((getline line < ours) > 0)  { i=index(line,"  "); o[substr(line,i+2)]=substr(line,1,i-1) }
  while ((getline line < gen)  > 0)  { g[line]=1 }
}
{
  i=index($0,"  "); h=substr($0,1,i-1); p=substr($0,i+2)
  if (p in b)      { print (b[p]==h ? "base" : "MODIFIED") "\t" p "\t" h }
  else if (p in o) { print (o[p]==h ? "verified" : "MISMATCH") "\t" p "\t" h }
  else if (p in g) { print "generated\t" p "\t" h }
  else             { print "UNACCOUNTED\t" p "\t" h }
}' "${tmp}/image.txt" > "${tmp}/classified.txt"

count() { grep -c "^$1	" "${tmp}/classified.txt" || true; }
n_base=$(count base);      n_ver=$(count verified)
n_gen=$(count generated);  n_mod=$(count MODIFIED)
n_mis=$(count MISMATCH);   n_un=$(count UNACCOUNTED)
n_total=$(wc -l < "${tmp}/classified.txt")

echo
printf 'base (unchanged)   %6d\n' "${n_base}"
printf 'verified (tarball) %6d\n' "${n_ver}"
printf 'generated          %6d\n' "${n_gen}"
printf 'MODIFIED base      %6d\n' "${n_mod}"
printf 'MISMATCH vs tarball%6d\n' "${n_mis}"
printf 'UNACCOUNTED        %6d\n' "${n_un}"
printf '                   ------\n'
printf 'total              %6d\n' "${n_total}"

if (( n_mod || n_mis || n_un )); then
  echo
  echo "--- files that do not check out ---"
  grep -E '^(MODIFIED|MISMATCH|UNACCOUNTED)	' "${tmp}/classified.txt" \
    | awk -F'\t' '{printf "  %-12s %s\n", $1, $2}'
fi

# --- manifest -------------------------------------------------------------
{
  printf '{\n'
  printf '  "image": "%s",\n'  "${IMAGE}"
  printf '  "base": "%s",\n'   "${BASE}"
  printf '  "version": "%s",\n' "${VERSION}"
  printf '  "triple": "%s",\n'  "${TRIPLE}"
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "counts": { "base": %d, "verified": %d, "generated": %d, "modified": %d, "mismatch": %d, "unaccounted": %d, "total": %d },\n' \
    "${n_base}" "${n_ver}" "${n_gen}" "${n_mod}" "${n_mis}" "${n_un}" "${n_total}"
  printf '  "complete": %s,\n' "$( (( n_mod || n_mis || n_un )) && echo false || echo true )"
  printf '  "files": [\n'
  awk -F'\t' '{printf "    {\"class\":\"%s\",\"path\":\"%s\",\"sha256\":\"%s\"}%s\n", $1, $2, $3, (NR==nl?"":",")}' \
    nl="$(wc -l < "${tmp}/classified.txt")" "${tmp}/classified.txt"
  printf '  ]\n}\n'
} > "${MANIFEST}"

echo
echo "manifest: ${MANIFEST}"

if (( n_mod || n_mis || n_un )); then
  echo
  echo "FAIL — image contains files that are not accounted for" >&2
  exit 1
fi
echo "OK — every file in the image is accounted for"
