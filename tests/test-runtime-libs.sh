#!/usr/bin/env bash
#
# Run a node through its whole life and prove it never asks for a library the
# runtime base does not have.
#
# The runtime base is distroless base-nossl: glibc and nothing else. That is
# enough because the official binaries link only libc, libm and libpthread —
# scripts/check-runtime-deps.sh proves that statically before every build. What
# static analysis cannot see is a library requested at RUNTIME: glibc dlopen()s
# libgcc_s the first time a program cancels or exits a thread or takes a
# backtrace, and NSS can load modules for name resolution. Those fail when the
# code path runs, not at startup — possibly long after `make smoke` passed.
#
# So this watches the loader directly. LD_DEBUG=libs makes glibc log every
# library it looks for, including dlopen()s it performs itself, and the node is
# driven through the paths where a lazy load would happen:
#
#   startup and RPC, wallet creation and a spend, 110 mined blocks
#   RPCs that THROW (C++ exceptions: unwinding)
#   a hostname resolved through NSS (/etc/hosts via the container)
#   shutdown by RPC `stop`, a restart onto the same datadir, shutdown by SIGTERM
#
# bitcoin-cli is checked too: LD_DEBUG is in the container's environment, so
# every `docker exec`'d bitcoin-cli logs its own loads.
#
# Run natively on each architecture in CI, so arm64 is proven by execution and
# not by inference from amd64. Written 2026-09-26 when the base moved from cc to
# base-nossl; measured then: both binaries, both bases, both arches, requested
# only libc.so.6, libm.so.6 and libpthread.so.0.
#
#   usage: tests/test-runtime-libs.sh [image-ref]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" ]]; then
  IMAGE_REF="$(make -s -C "${REPO_ROOT}" print-image-ref)"
fi
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# Exactly what the binaries NEED. glibc 2.36 has the files and dns NSS backends
# built in, so resolution loads nothing further — measured, not assumed. If a
# future glibc or Core release makes this list grow, that is the point: the
# test fails, and the new entry is added here only once the base is known to
# carry it (check-runtime-deps.sh will say).
ALLOWED="libc.so.6 libm.so.6 libpthread.so.0"

WORK="$(mktemp -d)"
NODE="runtime-libs-$$"
cleanup() { docker rm -f "${NODE}" >/dev/null 2>&1 || true; rm -rf "${WORK}"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); }

# bitcoin-cli inside the running container. Its stderr — where LD_DEBUG writes —
# is appended to one file, so its library requests are checked like the node's.
cli() { docker exec "${NODE}" bitcoin-cli -regtest -datadir=/data "$@" 2>>"${WORK}/cli-ld.log"; }

# Wait until RPC answers rather than sleeping a fixed time: a slow runner would
# otherwise fail on timing, and a fast one would waste it.
wait_rpc() {
  local i
  for (( i = 0; i < 60; i++ )); do
    cli getblockcount >/dev/null 2>&1 && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' "${NODE}" 2>/dev/null)" == "true" ]] || return 1
    sleep 1
  done
  return 1
}

echo "=== image under test: ${IMAGE_REF} ==="
echo "    allowed libraries: ${ALLOWED}"
echo

# 127.0.0.77 exists only in this container's /etc/hosts, so a connection
# attempt to it in the log proves the name went through NSS.
#
# -fallbackfee because regtest has no fee estimates, and without it the spend
# below is refused ("Fee estimation failed") — which the first, unchecked ad-hoc
# version of this trace never noticed, and so claimed a spend it never made.
docker run -d --name "${NODE}" -e LD_DEBUG=libs \
  --add-host runtime-libs.invalid:127.0.0.77 \
  "${IMAGE_REF}" -regtest -listen=0 -dnsseed=0 -debug=net -fallbackfee=0.0001 >/dev/null

echo "--- lifecycle ---"
if wait_rpc; then ok "node started and RPC answered"; else bad "node never answered RPC"; fi

if cli createwallet w >/dev/null && cli -generate 110 >/dev/null \
   && cli sendtoaddress "$(cli getnewaddress)" 1.5 >/dev/null; then
  ok "wallet created, 110 blocks mined, a transaction sent"
else
  bad "wallet / mining / send failed"
fi

# Each of these must FAIL — an RPC error is a C++ exception unwinding inside
# bitcoind. If one succeeded, the path this is here to exercise was not taken.
thrown=0
cli getblock nothex             >/dev/null 2>&1 || thrown=$((thrown + 1))
cli sendtoaddress not-an-addr 1 >/dev/null 2>&1 || thrown=$((thrown + 1))
cli getrawtransaction 00        >/dev/null 2>&1 || thrown=$((thrown + 1))
if (( thrown == 3 )); then ok "3 RPCs raised errors (exception unwinding exercised)"
else bad "only ${thrown}/3 RPCs raised errors"; fi

cli addnode runtime-libs.invalid:18444 onetry >/dev/null 2>&1 || true
resolved=0
for (( i = 0; i < 15; i++ )); do
  docker logs "${NODE}" 2>&1 | grep -q '127\.0\.0\.77:18444' && { resolved=1; break; }
  sleep 1
done
if (( resolved )); then ok "hostname resolved through NSS (/etc/hosts)"
else bad "the NSS lookup was not observed — name resolution untested"; fi

height="$(cli getblockcount)"
cli stop >/dev/null
rc="$(docker wait "${NODE}")"
if [[ "${rc}" == 0 ]]; then ok "shutdown via RPC stop: exit 0"; else bad "shutdown via RPC stop: exit ${rc}"; fi

docker start "${NODE}" >/dev/null
if wait_rpc && [[ "$(cli getblockcount)" == "${height}" ]]; then
  ok "restarted onto the same datadir at height ${height}"
else
  bad "restart did not come back at height ${height}"
fi

docker stop -t 30 "${NODE}" >/dev/null
rc="$(docker inspect -f '{{.State.ExitCode}}' "${NODE}")"
if [[ "${rc}" == 0 ]]; then ok "shutdown via SIGTERM: exit 0"; else bad "shutdown via SIGTERM: exit ${rc}"; fi

docker logs "${NODE}" >"${WORK}/node.log" 2>&1
n_done="$(grep -c 'Shutdown done' "${WORK}/node.log" || true)"
if [[ "${n_done}" == 2 ]]; then ok "both shutdowns completed ('Shutdown done' x2)"
else bad "expected 2 completed shutdowns, saw ${n_done}"; fi

# --- what the loader asked for -------------------------------------------
echo
echo "--- libraries requested ---"
check_loads() { # <label> <file>
  local label="$1" file="$2" seen extra
  # `|| true`: with no trace at all, grep matches nothing and pipefail would end
  # the script right here — failing, but silently, before the line below that
  # says why. Found by mutation (LD_DEBUG removed): the run just stopped.
  seen="$(grep -oE 'find library=[^ ;]+' "${file}" | sed 's/find library=//' | sort -u || true)"
  # LD_DEBUG must actually have been honoured, or an empty list would pass.
  if ! grep -qx 'libc.so.6' <<<"${seen}"; then
    bad "${label}: no loader trace (LD_DEBUG not honoured?) — nothing was checked"
    return
  fi
  extra="$(grep -vxF -f <(tr ' ' '\n' <<<"${ALLOWED}") <<<"${seen}" || true)"
  if [[ -z "${extra}" ]]; then
    ok "${label} requested only: $(paste -sd' ' <<<"${seen}")"
  else
    bad "${label} requested libraries outside the allowlist: $(paste -sd' ' <<<"${extra}")"
  fi
  if grep -qiE 'cannot open shared object|error while loading shared libraries' "${file}"; then
    bad "${label}: the loader reported a library it could not open"
  fi
}
check_loads "bitcoind" "${WORK}/node.log"
check_loads "bitcoin-cli" "${WORK}/cli-ld.log"

echo
echo "=============================================="
printf 'runtime library tests: %d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 )) || exit 1
echo "OK — bitcoind and bitcoin-cli load nothing beyond glibc, through a full lifecycle"
