#!/usr/bin/env bash
#
# Reconstruct a release's signed SHA256SUMS from guix.sigs.
#
# WHY THIS EXISTS: bitcoincore.org withdraws releases. Measured 2026-09-12,
# bitcoin-core-30.0 and 30.1 are gone from its index entirely, while 22.0-29.0,
# 30.2, 30.3 and 31.1 are still served. guix.sigs, by contrast, retains the
# attestations for withdrawn releases (30.0 has 24 signer directories, 30.1 has
# 18). So the trust anchor outlives the download.
#
# The two sources are not shaped the same. bitcoincore.org publishes ONE
# SHA256SUMS and ONE SHA256SUMS.asc carrying every builder's signature
# concatenated. guix.sigs keeps each builder's own copy of the sums plus their
# individual detached signature, under <version>/<signer>/. Reproducible builds
# mean those copies agree: for 31.1, all 16 signers' all.SHA256SUMS are
# byte-identical to what bitcoincore.org serves.
#
# So the reconstruction is: take the sums content that the most builders agree
# on, and concatenate their signatures. GnuPG accepts concatenated armored
# detached signatures, which is exactly what upstream's .asc already is.
#
# THIS RECOVERS THE SUMS, NOT THE TARBALL. If upstream has withdrawn a release,
# this tells you the correct hash of a file you must obtain elsewhere — your own
# published image or archive. Verifying and obtaining are different problems.
#
#   usage: scripts/fetch-sums-from-guix-sigs.sh <version> <outdir>
#
set -euo pipefail

VERSION="${1:?usage: fetch-sums-from-guix-sigs.sh <version> <outdir>}"
OUTDIR="${2:?usage: fetch-sums-from-guix-sigs.sh <version> <outdir>}"
GUIX_SIGS_URL="${GUIX_SIGS_URL:-https://github.com/bitcoin-core/guix.sigs.git}"
# 'all' covers the codesigned Windows/macOS binaries too and is what
# bitcoincore.org publishes; 'noncodesigned' is the other variant upstream keeps.
SUMS_VARIANT="${SUMS_VARIANT:-all}"

mkdir -p "${OUTDIR}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo ">> cloning guix.sigs for ${VERSION} attestations"
git clone --quiet --filter=blob:none "${GUIX_SIGS_URL}" "${tmp}/gs"
GUIX_COMMIT="$(git -C "${tmp}/gs" rev-parse HEAD)"

vdir="${tmp}/gs/${VERSION}"
[[ -d "${vdir}" ]] || { echo "guix.sigs has no directory for ${VERSION}" >&2; exit 1; }

# Group signer directories by the hash of their sums file. Reproducible builds
# mean they should all agree; if they do not, that disagreement is the finding.
: > "${tmp}/index"
shopt -s nullglob
for d in "${vdir}"/*/; do
  sums="${d}${SUMS_VARIANT}.SHA256SUMS"
  asc="${sums}.asc"
  [[ -f "${sums}" && -f "${asc}" ]] || continue
  printf '%s %s\n' "$(sha256sum "${sums}" | cut -d' ' -f1)" "${d}" >> "${tmp}/index"
done
[[ -s "${tmp}/index" ]] || {
  echo "no ${SUMS_VARIANT}.SHA256SUMS pairs found under ${VERSION}/" >&2; exit 1; }

winner="$(awk '{print $1}' "${tmp}/index" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
n_groups="$(awk '{print $1}' "${tmp}/index" | sort -u | wc -l)"
n_win="$(grep -c "^${winner} " "${tmp}/index")"
n_all="$(wc -l < "${tmp}/index")"

if (( n_groups > 1 )); then
  echo "WARNING: builders do not agree on ${SUMS_VARIANT}.SHA256SUMS for ${VERSION}" >&2
  echo "  ${n_groups} distinct contents across ${n_all} signers; using the majority (${n_win})." >&2
  echo "  For a reproducible build this should not happen. Investigate before trusting it." >&2
fi

# Emit the agreed sums, and every signature over exactly that content.
first="$(grep "^${winner} " "${tmp}/index" | head -1 | awk '{print $2}')"
cp "${first}${SUMS_VARIANT}.SHA256SUMS" "${OUTDIR}/SHA256SUMS"
: > "${OUTDIR}/SHA256SUMS.asc"
while read -r _ d; do
  cat "${d}${SUMS_VARIANT}.SHA256SUMS.asc" >> "${OUTDIR}/SHA256SUMS.asc"
done < <(grep "^${winner} " "${tmp}/index")

echo ">> guix.sigs @ ${GUIX_COMMIT}"
echo ">> ${n_win} of ${n_all} signers agree; wrote ${OUTDIR}/SHA256SUMS{,.asc}"
echo ">> NOTE: this recovers the signed sums only. The tarball must come from"
echo ">>       upstream or your own archive, and is checked against these sums."
