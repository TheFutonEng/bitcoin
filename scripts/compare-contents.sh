#!/usr/bin/env bash
#
# Prove two images contain exactly the same files, from their contents manifests.
#
# The release uses this to join two halves that are otherwise separate. The
# preflight job builds each platform on a NATIVE runner and boots it — the only
# place an arm64 binary is actually executed. The publish job then cross-builds
# every platform into one index on amd64 and pushes that. Those are two builds.
# They are meant to be identical in content, but "meant to be" is the phrase
# this repo keeps having to replace with a check.
#
# Contents manifests hash every regular file and record every symlink target,
# so equal file lists mean the published image holds byte-for-byte the files of
# the image that booted. Only file content is compared: the image digests differ
# legitimately, because the local build does not rewrite layer timestamps and
# carries different labels.
#
#   usage: scripts/compare-contents.sh <booted-manifest.json> <published-manifest.json>
#
set -euo pipefail

A="${1:?usage: compare-contents.sh <booted-manifest.json> <published-manifest.json>}"
B="${2:?usage: compare-contents.sh <booted-manifest.json> <published-manifest.json>}"
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

files() { jq -r '.files[] | "\(.sha256)  \(.path)"' "$1" | sort; }

a_files="$(files "${A}")"; b_files="$(files "${B}")"
# An empty list on both sides would compare equal and prove nothing — the same
# fail-open verify-contents.sh once had. A real image has well over a thousand.
for side in "${A}:${a_files}" "${B}:${b_files}"; do
  n="$(grep -c . <<<"${side#*:}" || true)"
  (( n >= 100 )) || { echo "FATAL: ${side%%:*} lists only ${n} files — refusing to compare" >&2; exit 1; }
done

triple_a="$(jq -r .triple "${A}")"; triple_b="$(jq -r .triple "${B}")"
[[ "${triple_a}" == "${triple_b}" ]] || {
  echo "FATAL: comparing different platforms: ${triple_a} vs ${triple_b}" >&2; exit 1; }

if diff <(printf '%s\n' "${a_files}") <(printf '%s\n' "${b_files}") >/dev/null; then
  echo "OK — ${triple_a}: the published image has exactly the files of the booted one ($(grep -c . <<<"${a_files}") files)"
else
  echo "FATAL: ${triple_a}: the published image's files differ from the booted image's" >&2
  diff <(printf '%s\n' "${a_files}") <(printf '%s\n' "${b_files}") | sed 's/^/  /' | head -20 >&2
  exit 1
fi
