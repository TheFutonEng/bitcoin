#!/usr/bin/env bash
#
# How configuration and the datadir reach the container — and proof that the
# ways they can silently NOT reach it stay fixed.
#
# The bug this exists for: `CMD ["-datadir=/data", "-printtoconsole"]`. Docker
# REPLACES CMD with user arguments rather than appending to them, so the moment
# a consumer passed any flag at all the datadir silently reverted to
# /home/nonroot/.bitcoin on the container layer. The mounted volume was ignored,
# the node started and logged normally, and the chain vanished on --rm. Nothing
# warned, and nothing here would have caught it. The flags now live in
# ENTRYPOINT, which Docker PREPENDS.
#
# The second thing it exists for: Bitcoin Core does NOT fail on an unrecognised
# option in a config file. It prints "Ignoring unknown configuration value" and
# continues. So examples/bitcoin.conf could name options that Core has since
# renamed or dropped, a user could copy it, and their settings would quietly do
# nothing. Booting the example proves it parses; only checking the names against
# the shipped binary proves it is still true.
#
#   usage: tests/test-config.sh [image-ref]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_REF="${1:-}"
if [[ -z "${IMAGE_REF}" ]]; then
  IMAGE_REF="$(make -s -C "${REPO_ROOT}" print-image-ref)"
fi
EXAMPLE="${REPO_ROOT}/examples/bitcoin.conf"
[[ -f "${EXAMPLE}" ]] || { echo "missing examples/bitcoin.conf" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
chmod 755 "${WORK}"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); }
note(){ printf '  %s\n' "$*"; }

# Bitcoin Core writes files as uid 65532. A bind-mounted directory therefore
# ends up containing subdirectories this user cannot remove, so cleanup runs as
# root inside a container. The verifier base is used because the build has
# already pulled it and it is pinned by digest like everything else here.
CLEANUP_IMAGE="debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251"
scrub() {
  docker run --rm -v "${WORK}:/w" --entrypoint /bin/rm "${CLEANUP_IMAGE}" \
    -rf "/w/${1}" >/dev/null 2>&1 || true
}

# Run a node until it reports "Done loading", or until a deadline. Leaves the
# full log in $LOG. regtest with no peers and a tiny cache, so this costs
# seconds rather than minutes.
#
# DETACHED, not backgrounded with `&`. The first version used a background job
# and got two things wrong: it checked liveness before the container had started
# and so broke out of the loop immediately on every run, and the job's output
# escaped into the test transcript. `docker run -d` plus `docker logs` has
# neither problem, and the logs survive the container exiting. The three-second
# grace before the liveness check is the same guard `make smoke` needs, for the
# same reason.
LOG=""
boot() {
  LOG="$(mktemp)"
  local cid i loaded=1
  cid="$(docker run -d "$@" -regtest -connect=0 -listen=0 -dbcache=4 -maxmempool=5 2>"${LOG}")" || {
    return 1
  }
  for (( i = 0; i < 40; i++ )); do
    docker logs "${cid}" >"${LOG}" 2>&1 || true
    grep -q 'init message: Done loading' "${LOG}" && { loaded=0; break; }
    if (( i >= 3 )) && [[ "$(docker inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null)" != "true" ]]; then
      break
    fi
    sleep 1
  done
  docker stop -t 1 "${cid}" >/dev/null 2>&1 || true
  docker logs "${cid}" >"${LOG}" 2>&1 || true
  docker rm -f "${cid}" >/dev/null 2>&1 || true
  return "${loaded}"
}

echo "=== image under test: ${IMAGE_REF} ==="

# --- 1. the regression --------------------------------------------------
# Arguments must not displace the datadir. Asserted on the HOST directory
# rather than on the log, because the log looked perfectly healthy while this
# was broken — it reported a datadir, just not the one that was mounted.
echo
echo "--- datadir survives user arguments ---"
D="${WORK}/bind"; mkdir -p "${D}"; chmod 777 "${D}"
if boot -v "${D}:/data" "${IMAGE_REF}"; then
  if [[ -n "$(ls -A "${D}")" ]]; then
    ok "extra arguments passed: the mounted volume received the chain"
  else
    bad "extra arguments passed: the mounted volume is EMPTY — datadir was displaced"
  fi
else
  bad "node did not finish loading with a bind-mounted datadir"; tail -5 "${LOG}" >&2
fi
if grep -q 'Using data directory /data' "${LOG}"; then
  ok "datadir reported as /data"
else
  bad "datadir was not /data: $(grep -m1 'Using data directory' "${LOG}" || echo '<none>')"
fi
rm -f "${LOG}"; scrub bind

# --- 2. the datadir is still overridable --------------------------------
# Guards against a future "fix" that hardcodes the datadir somewhere it cannot
# be changed. Bitcoin Core takes the LAST duplicate on the command line.
echo
echo "--- an explicit -datadir still wins ---"
if boot --tmpfs /other:uid=65532,gid=65532,mode=0700 "${IMAGE_REF}" -datadir=/other; then
  if grep -q 'Using data directory /other' "${LOG}"; then
    ok "-datadir=/other overrode the image default"
  else
    bad "-datadir=/other was ignored"
  fi
else
  bad "node did not finish loading with an overridden datadir"; tail -5 "${LOG}" >&2
fi
rm -f "${LOG}"

# --- 3. a fresh volume is usable without a host chown --------------------
# /data exists in the image owned by 65532 so Docker seeds new volumes with that
# ownership. Before that, this exact command died on
# "Unable to open settings file /data/settings.json.tmp for writing".
echo
echo "--- a fresh named volume needs no preparation ---"
VOL="cfgtest-vol-$$"
docker volume rm "${VOL}" >/dev/null 2>&1 || true
if boot -v "${VOL}:/data" "${IMAGE_REF}"; then
  ok "fresh named volume: node started with no host-side chown"
else
  bad "fresh named volume: node failed to start"; tail -5 "${LOG}" >&2
fi
rm -f "${LOG}"
docker volume rm "${VOL}" >/dev/null 2>&1 || true

# --- 4. the documented config path actually works ------------------------
# "Config file: <path>" alone is NOT sufficient: bitcoind prints that line with
# "(not found, skipping)" appended when the file is absent, so grepping for the
# path would pass in both cases. The absence of that suffix is the assertion.
echo
echo "--- examples/bitcoin.conf is read when mounted ---"
cp "${EXAMPLE}" "${WORK}/bitcoin.conf"; chmod 644 "${WORK}/bitcoin.conf"
D2="${WORK}/withconf"; mkdir -p "${D2}"; chmod 777 "${D2}"
if boot -v "${D2}:/data" -v "${WORK}/bitcoin.conf:/data/bitcoin.conf:ro" "${IMAGE_REF}"; then
  if grep -q 'Config file: /data/bitcoin.conf$' "${LOG}"; then
    ok "config file read (no 'not found, skipping')"
  else
    bad "config not read: $(grep -m1 'Config file:' "${LOG}" || echo '<no line>')"
  fi
  # The whole reason the name check below exists.
  if grep -q 'Ignoring unknown configuration value' "${LOG}"; then
    bad "example contains an option this bitcoind does not know:"
    grep 'Ignoring unknown configuration value' "${LOG}" | sed 's/^/        /' >&2
  else
    ok "no 'Ignoring unknown configuration value' warnings"
  fi
else
  bad "node did not finish loading with the example config"; tail -5 "${LOG}" >&2
fi
rm -f "${LOG}"; scrub withconf

# --- 5. every option the example names still exists ----------------------
# Catches the rot that booting cannot: the example is almost entirely comments,
# so a renamed or removed option would produce no warning at all.
echo
echo "--- every option named in the example exists in this bitcoind ---"
docker run --rm --entrypoint /usr/local/bin/bitcoind "${IMAGE_REF}" -help 2>&1 \
  | grep -oE '^[[:space:]]+-[a-zA-Z0-9]+' | tr -d ' -' | sort -u > "${WORK}/opts.txt"
n_opts="$(wc -l < "${WORK}/opts.txt")"
(( n_opts > 50 )) || { echo "only ${n_opts} options parsed from -help; refusing to trust that" >&2; exit 1; }
note "${n_opts} options advertised by bitcoind -help"

# `bitcoind -help` is NOT exhaustive. -regtest works and is used throughout this
# repo, but appears only as an allowed value of -chain, never as its own entry.
# Anything added here needs the same kind of evidence, not a hunch.
UNLISTED_BUT_VALID="regtest"

unknown=0
while read -r opt; do
  [[ -n "${opt}" ]] || continue
  grep -qx "${opt}" "${WORK}/opts.txt" && continue
  grep -qx "${opt}" <<<"${UNLISTED_BUT_VALID}" && continue
  bad "examples/bitcoin.conf names '${opt}', which this bitcoind does not advertise"
  unknown=$((unknown + 1))
done < <(grep -oE '^#?[[:space:]]*[a-zA-Z0-9]+=' "${EXAMPLE}" | tr -d '#= ' | sort -u)

if (( unknown == 0 )); then
  n_named="$(grep -oE '^#?[[:space:]]*[a-zA-Z0-9]+=' "${EXAMPLE}" | tr -d '#= ' | sort -u | grep -c .)"
  ok "all ${n_named} options named in the example are real"
fi

echo
echo "=============================================="
printf 'config tests: %d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 )) || exit 1
echo "OK — configuration reaches the container and the example is not stale"
