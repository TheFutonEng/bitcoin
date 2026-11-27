#!/usr/bin/env bash
#
# Prove the runtime base can load the binaries we ship — before building.
#
# The base is distroless base-nossl: glibc and nothing else. That is enough
# today because upstream's own release build (contrib/guix/symbol-check.py)
# only lets bitcoind link libc, libm, libpthread and the dynamic loader. This
# script turns "enough today" into a check that runs on every build, so the day
# a Bitcoin Core release — or a base bump — breaks it, the failure names the
# library instead of surfacing as a container that will not start.
#
# Two ways a binary can need a library, and this checks both:
#
#   NEEDED   listed in the ELF dynamic section; the loader resolves it at
#            startup. Every entry must exist in the base for this platform.
#
#   lazy     glibc itself dlopen()s libgcc_s.so.1 the first time a program
#            calls pthread_cancel, pthread_exit or backtrace, to unwind the
#            stack — a dependency no NEEDED entry shows, and one that fails
#            at that moment rather than at startup. What "fails" means
#            depends on the import, so there are two classes:
#
#     fatal      pthread_cancel, pthread_exit: glibc ABORTS the process
#                ("libgcc_s.so.1 must be installed for pthread_cancel to
#                work"). dlopen and friends are here too: a binary that can
#                dlopen can load anything. Always a failure without libgcc_s.
#
#     degrading  backtrace, backtrace_symbols(_fd): without libgcc_s,
#                backtrace() returns 0 frames and the program carries on.
#                Measured 2026-11-27 on base-nossl-debian13 (glibc 2.41),
#                and re-proven on every image by tests/test-runtime-libs.sh.
#                Still a failure unless the binary:import pair is listed in
#                DEGRADED_OK after review, so a new import stays a decision.
#
#            Through 31.x neither shipped binary imported any of them. 32.x's
#            bitcoin-cli imports backtrace, through the Cap'n Proto/kj library
#            behind its new -ipcconnect support (kj records a stack trace when
#            it constructs an exception); Bitcoin Core's own sources never
#            call it. It only runs when bitcoin-cli talks IPC to a
#            bitcoin-node, which this image does not ship. The cost of
#            accepting it: such an error would carry an empty stack trace. The
#            alternative, cc-debian13, scanned at 56 findings against 14.
#
# Static analysis, so it cannot see everything; tests/test-runtime-libs.sh is
# the runtime half, and runs natively on each architecture in CI.
#
#   usage: scripts/check-runtime-deps.sh <version> <triple> <platform>
#
# env:
#   RUNTIME_BASE=    the base to check against (the Makefile passes its pin)
#   SHIP_BINARIES=   binaries the image ships (default: bitcoind bitcoin-cli)
#   UPSTREAM_DIR=    where the verified tarball lives (default: <repo>/upstream)
#   DEGRADED_OK=     reviewed binary:import pairs that may use a degrading
#                    import without libgcc_s (default: bitcoin-cli:backtrace)
#
set -euo pipefail

VERSION="${1:?usage: check-runtime-deps.sh <version> <triple> <platform>}"
TRIPLE="${2:?usage: check-runtime-deps.sh <version> <triple> <platform>}"
PLATFORM="${3:?usage: check-runtime-deps.sh <version> <triple> <platform>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${UPSTREAM_DIR:-${REPO_ROOT}/upstream}"
SHIP_BINARIES="${SHIP_BINARIES:-bitcoind bitcoin-cli}"
TARBALL="${UPSTREAM_DIR}/bitcoin-${VERSION}-${TRIPLE}.tar.gz"
RUNTIME_BASE="${RUNTIME_BASE:-$(sed -n 's/^RUNTIME_BASE[[:space:]]*?*=[[:space:]]*\(.*\)$/\1/p' "${REPO_ROOT}/Makefile" | head -1)}"
[[ -n "${RUNTIME_BASE}" ]] || { echo "could not determine RUNTIME_BASE" >&2; exit 1; }
[[ -f "${TARBALL}" ]] || { echo "missing ${TARBALL} — run: make fetch-tarball PLATFORM=${PLATFORM}" >&2; exit 1; }
command -v readelf >/dev/null || { echo "readelf not found (it ships with binutils)" >&2; exit 1; }

# Imports through which glibc loads libgcc_s at runtime, in the two classes the
# header describes. dlopen is fatal because a binary that can dlopen can load
# anything, and nothing static can tell what.
LAZY_FATAL='^(dlopen|dlmopen|__libc_dlopen_mode|pthread_cancel|pthread_exit)$'
LAZY_DEGRADING='^(backtrace|backtrace_symbols|backtrace_symbols_fd)$'
DEGRADED_OK="${DEGRADED_OK-bitcoin-cli:backtrace}"
degraded_ok() { [[ " ${DEGRADED_OK} " == *" $1:$2 "* ]]; }

tmp="$(mktemp -d)"; cid=""
cleanup() { rm -rf "${tmp}"; [[ -z "${cid}" ]] || docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- what the base provides, for THIS platform ------------------------------
# By the platform's own manifest digest, for the reason verify-contents.sh
# gives: on the classic image store an index-digest reference holds one
# platform, and asking it for another fails.
base_ref="${RUNTIME_BASE}"
if listing="$("${REPO_ROOT}/scripts/list-platforms.sh" "${RUNTIME_BASE}" 2>/dev/null)"; then
  d="$(awk -v p="${PLATFORM}" '$1 == p || index($1, p "/") == 1 { print $2 }' <<<"${listing}")"
  [[ -n "${d}" && "${d}" != *$'\n'* ]] || {
    echo "base ${RUNTIME_BASE} has no single ${PLATFORM} image (got: '${d}')" >&2; exit 1; }
  base_ref="${RUNTIME_BASE%@*}@${d}"
fi
cid="$(docker create --platform "${PLATFORM}" "${base_ref}" /nonexistent-never-run 2>"${tmp}/err")" \
  || { echo "cannot create ${base_ref}:" >&2; sed 's/^/  /' "${tmp}/err" >&2; exit 1; }
# The export's status is checked on its own, as in verify-contents.sh: an empty
# listing would make every library "missing", which fails — but a truncated one
# could make a wrong answer look plausible.
set +e
docker export "${cid}" | tar -t > "${tmp}/base-files"
rc=${PIPESTATUS[0]}
set -e
(( rc == 0 )) || { echo "docker export of ${base_ref} failed (exit ${rc})" >&2; exit 1; }
(( $(wc -l < "${tmp}/base-files") >= 100 )) || { echo "base listing is implausibly short" >&2; exit 1; }
# A library "exists" if some path in the base ends in /<name> — a file or a
# symlink; the loader follows either. ld.so's own path (lib64/ on amd64) is
# found the same way.
#
# An exact comparison of the last path component, never a regex built from the
# name: `libstdc++.so.6` is a regex in which `++` is a quantifier, and the first
# version of this function reported it missing from a base that ships it.
# Found by mutation-testing this script, not by reading it.
has_lib() { awk -F/ -v n="$1" '$NF == n { found = 1 } END { exit !found }' "${tmp}/base-files"; }

# --- what the binaries need ---------------------------------------------------
mkdir -p "${tmp}/bin"
for b in ${SHIP_BINARIES}; do
  tar -xzf "${TARBALL}" -C "${tmp}/bin" --strip-components=2 "bitcoin-${VERSION}/bin/${b}" \
    || { echo "${b} is not in ${TARBALL##*/}" >&2; exit 1; }
done

echo ">> ${PLATFORM}: ${SHIP_BINARIES} against ${base_ref}"
fail=0
for b in ${SHIP_BINARIES}; do
  f="${tmp}/bin/${b}"
  needed="$(readelf -d "${f}" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')"
  [[ -n "${needed}" ]] || { echo "  FAIL  ${b}: no NEEDED entries — not a dynamic ELF?" >&2; fail=1; continue; }
  while read -r lib; do
    if has_lib "${lib}"; then printf '  OK    %-12s needs %s\n' "${b}" "${lib}"
    else printf '  FAIL  %-12s needs %s — NOT in the runtime base\n' "${b}" "${lib}"; fail=1; fi
  done <<<"${needed}"

  undef="$(readelf --dyn-syms -W "${f}" | awk '$7 == "UND" { sub(/@.*/, "", $8); print $8 }' | sort -u)"
  fatal="$(grep -E "${LAZY_FATAL}" <<<"${undef}" | paste -sd, - || true)"
  degrading="$(grep -E "${LAZY_DEGRADING}" <<<"${undef}" || true)"
  if [[ -z "${fatal}" && -z "${degrading}" ]]; then
    printf '  OK    %-12s imports nothing that makes glibc load libgcc_s\n' "${b}"
  elif has_lib libgcc_s.so.1; then
    printf '  OK    %-12s imports %s; libgcc_s.so.1 is in the base\n' "${b}" \
      "$(paste -sd, - <<<"$(printf '%s\n%s\n' "${fatal//,/$'\n'}" "${degrading}" | grep . )")"
  else
    if [[ -n "${fatal}" ]]; then
      printf '  FAIL  %-12s imports %s, so glibc will dlopen libgcc_s.so.1 at runtime —\n' "${b}" "${fatal}"
      printf '        and the base does not have it. It would start, then ABORT when that path runs.\n'
      fail=1
    fi
    while read -r sym; do
      [[ -n "${sym}" ]] || continue
      if degraded_ok "${b}" "${sym}"; then
        printf '  OK    %-12s imports %s: degrades without libgcc_s (0 frames, no crash); reviewed, in DEGRADED_OK\n' "${b}" "${sym}"
      else
        printf '  FAIL  %-12s imports %s; without libgcc_s it degrades rather than crashes, but\n' "${b}" "${sym}"
        printf '        %s:%s is not in DEGRADED_OK. Find what calls it before accepting it.\n' "${b}" "${sym}"
        fail=1
      fi
    done <<<"${degrading}"
  fi
done

echo
if (( fail )); then
  echo "FAIL — the runtime base cannot fully load the shipped binaries." >&2
  echo "Either this Bitcoin Core version needs more than glibc (compare upstream's" >&2
  echo "contrib/guix/symbol-check.py ELF_ALLOWED_LIBRARIES with the previous" >&2
  echo "version), or the base changed. A base that provides the library — e.g." >&2
  echo "distroless cc-debian13 for libgcc_s/libstdc++ — is the fix, not copying it in." >&2
  exit 1
fi
echo "OK — every library the binaries need is in the runtime base"
