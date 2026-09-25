#!/usr/bin/env bash
#
# Negative tests for the signature threshold — the gate this whole repo rests on.
#
# CLAUDE.md invariant 6 says the threshold logic lives in two places on purpose:
# `scripts/verify.sh` and the verifier stage of the `Dockerfile`. `check-pins.sh`
# already asserts the two agree on the *value* of MIN_GOOD_SIGS. That proves
# nothing about the parsing, and the parsing is where both real bugs were:
#
#   - matching VALIDSIG field 3 (a signing SUBKEY) against an allowlist of
#     PRIMARY fingerprints, which silently dropped 4 of 11 good signatures;
#   - counting signatures from expired keys, because gpg emits EXPKEYSIG *and*
#     VALIDSIG for the same signature.
#
# Both bugs were present in BOTH copies, because the two copies are the same
# hand-written parser duplicated rather than two independent implementations.
# Duplication defends against one copy being edited. It does not defend against
# the logic being wrong. This is the test that does.
#
# Method: take the real committed SHA256SUMS.asc, split it into its individual
# signature packets, and reassemble fixtures with a known number of distinct
# acceptable signers. Feed each fixture to BOTH gates and assert they reach the
# same verdict AND report the same count.
#
# Two cases additionally mint a throwaway key in a temporary GNUPGHOME, because
# the property they test cannot be reached with upstream's packets alone. That
# key material is ephemeral, never leaves the temp directory, and is never
# committed. Every other packet used is a genuine upstream builder signature;
# the only thing being varied is which subset the verifier is shown.
#
# NOTE ON FIXTURES: the fixtures are built from the real artifacts and fed to the
# real gates — the actual `scripts/verify.sh` and the actual `Dockerfile`. This
# file asserts an outcome; it never supplies the property under test. That
# distinction has burned this repo before: a `verify-contents.sh` test once used
# a hand-built fixture that set the very label the Dockerfile was supposed to
# produce, so it validated the script while the Dockerfile was broken.
#
#   usage: tests/test-threshold.sh [version] [triple]
#
set -euo pipefail

VERSION="${1:-31.1}"
TRIPLE="${2:-x86_64-linux-gnu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${REPO_ROOT}/upstream"
KEYS="${REPO_ROOT}/keys"
TARBALL="bitcoin-${VERSION}-${TRIPLE}.tar.gz"
# The Dockerfile selects its tarball from TARGETARCH, so the build has to be
# told the platform matching the fixture's triple, or it would look for a
# tarball this test never staged. The verifier stage runs on the build host
# either way, so this needs no emulation.
case "${TRIPLE}" in
  x86_64-linux-gnu)  PLATFORM=linux/amd64 ;;
  aarch64-linux-gnu) PLATFORM=linux/arm64 ;;
  *) echo "no platform for triple ${TRIPLE}" >&2; exit 2 ;;
esac

# Read the threshold from the Makefile rather than hardcoding it, so raising
# MIN_GOOD_SIGS does not silently turn the accept case into a failing test.
# check-pins.sh is what asserts the Makefile, Dockerfile and verify.sh agree on
# this number, so reading any one of the three is enough here.
THRESHOLD="$(sed -n 's/^MIN_GOOD_SIGS[[:space:]]*?*=[[:space:]]*\([0-9]\+\).*/\1/p' "${REPO_ROOT}/Makefile" | head -1)"
[[ -n "${THRESHOLD}" ]] || { echo "could not read MIN_GOOD_SIGS from Makefile" >&2; exit 1; }

# --- preconditions --------------------------------------------------------
for f in SHA256SUMS SHA256SUMS.asc "${TARBALL}"; do
  [[ -f "${UPSTREAM}/${f}" ]] || {
    echo "missing upstream/${f}" >&2
    echo "run: make fetch-tarball VERSION=${VERSION}" >&2
    exit 1
  }
done
command -v gpgsplit >/dev/null || { echo "gpgsplit not found (ships with gnupg)" >&2; exit 1; }
command -v docker   >/dev/null || { echo "docker not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0; fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); }

# --- split the real signature bundle into packets -------------------------
echo "=== splitting upstream/SHA256SUMS.asc into signature packets ==="
mkdir -p "${WORK}/packets"
gpg --dearmor < "${UPSTREAM}/SHA256SUMS.asc" > "${WORK}/packets/all.bin" 2>/dev/null
( cd "${WORK}/packets" && gpgsplit --prefix=p all.bin )

allowlist="$(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' \
             "${KEYS}/trusted-fingerprints.txt" | sort -u)"

# Classify each packet by the PRIMARY fingerprint that made it. This uses the
# same "last field of VALIDSIG" rule the gates use — which is fine, because this
# step only decides what to put in a fixture. The assertions below never consult
# it; they compare the two gates against an expected number that follows from
# how the fixture was constructed.
declare -a ALLOWED_PKTS=() UNKNOWN_PKTS=()
for pkt in "${WORK}/packets"/p*.sig; do
  # `|| true` is required, not decorative: gpgv exits non-zero for a signature it
  # cannot verify, and with `set -o pipefail` that would abort the script on the
  # first untrusted packet — the very packet this loop exists to classify.
  fpr="$(gpgv --keyring "${KEYS}/trusted-keyring.gpg" --status-fd 1 "${pkt}" "${UPSTREAM}/SHA256SUMS" 2>/dev/null \
         | awk '/^\[GNUPG:\] VALIDSIG/ {print (NF >= 12 ? $NF : $3)}' | head -1 || true)"
  if [[ -n "${fpr}" ]] && grep -qx "${fpr}" <<<"${allowlist}"; then
    ALLOWED_PKTS+=("${pkt}")
  else
    UNKNOWN_PKTS+=("${pkt}")
  fi
done

n_allowed=${#ALLOWED_PKTS[@]}
n_unknown=${#UNKNOWN_PKTS[@]}
note "${n_allowed} packets from allowlisted keys, ${n_unknown} from keys we do not trust"
note "threshold under test: ${THRESHOLD}"

if (( n_allowed < THRESHOLD + 1 )); then
  echo "FATAL: need at least $((THRESHOLD + 1)) allowlisted signatures to test both sides" >&2
  echo "       of the threshold; upstream/SHA256SUMS.asc has ${n_allowed}" >&2
  exit 1
fi

# --- fixture construction -------------------------------------------------
# Re-armor a set of packets into a PGP SIGNATURE block. `gpg --enarmor` emits an
# "ARMORED FILE" header; the base64 and CRC24 are identical either way, so
# retitling produces a bundle indistinguishable from the real thing.
make_fixture() {
  local out="$1"; shift
  cat "$@" > "${out}.bin"
  gpg --enarmor < "${out}.bin" 2>/dev/null | sed 's/ARMORED FILE/SIGNATURE/' > "${out}"
  rm -f "${out}.bin"
}

mkdir -p "${WORK}/fixtures"
F="${WORK}/fixtures"

# Mint a throwaway signer and produce (a) a detached signature packet over the
# real SHA256SUMS and (b) a keys/ directory that contains its public key, so the
# gates can actually see it. Both outputs land under "${WORK}/${tag}".
#
# `allowlist_it=yes` also appends the fingerprint to trusted-fingerprints.txt,
# which is what makes the expired-key case reach the code path under test: an
# expired key that is NOT allowlisted would be rejected by the intersection and
# the EXPKEYSIG handling would never be exercised.
#
# The keyring is regenerated with the repo's own scripts/build-keyring.sh rather
# than an inline `gpg --export`, so the artifact the Dockerfile verifies against
# is built the same way the committed one is.
forge_signer() {
  local tag="$1" uid="$2" expire="$3" allowlist_it="$4"
  local dir="${WORK}/${tag}" root="${WORK}/${tag}/root"
  mkdir -p "${root}/scripts"
  cp "${REPO_ROOT}/scripts/build-keyring.sh" "${root}/scripts/"
  cp -r "${KEYS}" "${root}/keys"

  local home="${dir}/gnupg"
  mkdir -p "${home}"; chmod 700 "${home}"

  GNUPGHOME="${home}" gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --quick-generate-key "${uid}" ed25519 sign "${expire}" >/dev/null 2>&1
  local fpr
  fpr="$(GNUPGHOME="${home}" gpg --batch --with-colons --list-keys 2>/dev/null \
         | awk -F: '/^fpr:/{print $10; exit}')"

  # Sign FIRST. gpg refuses to sign with an already-expired key, so for the
  # expired case the order matters: sign while valid, then let it lapse.
  GNUPGHOME="${home}" gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --detach-sign --output "${dir}/sig.bin" "${UPSTREAM}/SHA256SUMS" 2>/dev/null

  GNUPGHOME="${home}" gpg --batch --armor --export "${fpr}" > "${root}/keys/${fpr}.asc" 2>/dev/null
  if [[ "${allowlist_it}" == "yes" ]]; then
    printf '%s  # throwaway test key — never committed\n' "${fpr}" >> "${root}/keys/trusted-fingerprints.txt"
  fi
  "${root}/scripts/build-keyring.sh" >/dev/null

  printf '%s\n' "${fpr}"
}

# Block until gpgv actually reports the key as expired, rather than sleeping a
# guessed interval and hoping. A fixed `sleep` would make this test flaky on a
# loaded machine, which is worse than slow.
wait_for_expiry() {
  local keyring="$1" sig="$2" attempt
  for (( attempt = 0; attempt < 20; attempt++ )); do
    if gpgv --keyring "${keyring}" --status-fd 1 "${sig}" "${UPSTREAM}/SHA256SUMS" 2>/dev/null \
       | grep -q '^\[GNUPG:\] EXPKEYSIG'; then
      return 0
    fi
    sleep 1
  done
  echo "throwaway key never reported EXPKEYSIG — cannot test the expired path" >&2
  return 1
}

# Exactly at the threshold. Without this case the suite would pass against a
# parser that rejects everything, which is the failure mode this repo keeps
# rediscovering: an assertion that cannot fail proves nothing.
make_fixture "${F}/at-threshold.asc" "${ALLOWED_PKTS[@]:0:THRESHOLD}"

# One short.
make_fixture "${F}/under-threshold.asc" "${ALLOWED_PKTS[@]:0:THRESHOLD-1}"

# THRESHOLD packets, but one signer appears twice. A parser that counts VALIDSIG
# lines instead of distinct primary fingerprints sees enough and lets it through.
# gpgv does emit a VALIDSIG for each copy — verified, not assumed — so `sort -u`
# in both gates is load-bearing and this fixture is what holds it in place.
make_fixture "${F}/duplicate-signer.asc" \
  "${ALLOWED_PKTS[@]:0:THRESHOLD-1}" "${ALLOWED_PKTS[0]}"

# THRESHOLD packets, one from a key absent from the keyring entirely. Proves an
# extra signature cannot pad the count. Weaker than it looks — see the
# untrusted-in-keyring case below, which is the one that tests the allowlist.
if (( n_unknown > 0 )); then
  make_fixture "${F}/unknown-padding.asc" \
    "${ALLOWED_PKTS[@]:0:THRESHOLD-1}" "${UNKNOWN_PKTS[0]}"
fi

# --- the two gates --------------------------------------------------------
# Each returns rc, and prints the count it reported on stdout.

# scripts/verify.sh, run against a throwaway repo root. Copying rather than
# editing upstream/ in place is deliberate: a crash mid-run must not be able to
# leave the real trust anchor replaced by a five-signature fixture.
run_verify_sh() {
  local fixture="$1" keysdir="${2:-${KEYS}}" root="${WORK}/root"
  rm -rf "${root}"; mkdir -p "${root}/scripts" "${root}/upstream"
  cp "${REPO_ROOT}/scripts/verify.sh" "${root}/scripts/"
  cp -r "${keysdir}" "${root}/keys"
  cp "${UPSTREAM}/SHA256SUMS" "${root}/upstream/"
  cp "${fixture}" "${root}/upstream/SHA256SUMS.asc"
  cp -l "${UPSTREAM}/${TARBALL}" "${root}/upstream/${TARBALL}" 2>/dev/null \
    || cp "${UPSTREAM}/${TARBALL}" "${root}/upstream/${TARBALL}"

  local out rc=0
  out="$(MIN_GOOD_SIGS="${THRESHOLD}" "${root}/scripts/verify.sh" "${VERSION}" "${TRIPLE}" 2>&1)" || rc=$?
  printf '%s\n' "${out}" > "${WORK}/last-verify-sh.log"
  sed -n 's/^accepted signers (\([0-9]*\),.*/\1/p' <<<"${out}" | head -1
  return "${rc}"
}

# The Dockerfile's verifier stage — the real one, not a copy of its logic.
run_dockerfile() {
  local fixture="$1" keysdir="${2:-${KEYS}}" ctx="${WORK}/ctx"
  rm -rf "${ctx}"; mkdir -p "${ctx}/upstream"
  cp "${REPO_ROOT}/Dockerfile" "${ctx}/"
  cp "${REPO_ROOT}/.dockerignore" "${ctx}/" 2>/dev/null || true
  cp -r "${keysdir}" "${ctx}/keys"
  cp "${UPSTREAM}/SHA256SUMS" "${ctx}/upstream/"
  cp "${fixture}" "${ctx}/upstream/SHA256SUMS.asc"
  cp -l "${UPSTREAM}/${TARBALL}" "${ctx}/upstream/${TARBALL}" 2>/dev/null \
    || cp "${UPSTREAM}/${TARBALL}" "${ctx}/upstream/${TARBALL}"

  local out rc=0
  # --no-cache is load-bearing. buildkit caches SUCCESSFUL steps and does not
  # cache failing ones, so on a second run the accept case comes back CACHED with
  # no RUN output — no count to read, and the assertion fails for a reason that
  # has nothing to do with the gate. Worse, the asymmetry points the wrong way:
  # the one case that must keep passing is the one whose result gets reused. CI
  # hits this every time, because `make build` warms the same cache earlier in
  # the job. Caught by running this script twice in a row.
  out="$(docker buildx build \
        --no-cache \
        --target verifier \
        --network=none \
        --build-arg BITCOIN_VERSION="${VERSION}" \
        --platform "${PLATFORM}" \
        --build-arg MIN_GOOD_SIGS="${THRESHOLD}" \
        --progress=plain \
        --output=type=cacheonly \
        "${ctx}" 2>&1)" || rc=$?
  printf '%s\n' "${out}" > "${WORK}/last-dockerfile.log"
  sed -n 's/.*signatures accepted: \([0-9]*\) .*/\1/p' <<<"${out}" | head -1
  return "${rc}"
}

# --- assertions -----------------------------------------------------------
# A rejection must be for the RIGHT reason. `docker buildx build` exits non-zero
# for a missing base image, a daemon hiccup or a context error just as happily as
# for a failed threshold, and a test that only checks the exit code would go
# green on any of them. Same for verify.sh.
REJECT_MSG='FATAL: signature threshold not met'

check_case() {
  local name="$1" fixture="$2" expect="$3" expect_count="$4" keysdir="${5:-${KEYS}}"

  echo
  echo "--- ${name}: expect ${expect}, ${expect_count} accepted signer(s) ---"

  local v_count d_count v_rc=0 d_rc=0
  v_count="$(run_verify_sh  "${fixture}" "${keysdir}")" || v_rc=$?
  d_count="$(run_dockerfile "${fixture}" "${keysdir}")" || d_rc=$?

  note "verify.sh  rc=${v_rc} count=${v_count:-?}"
  note "Dockerfile rc=${d_rc} count=${d_count:-?}"

  # The headline assertion: the two gates parsed the same bytes the same way.
  if [[ "${v_count}" == "${d_count}" ]]; then
    ok "${name}: both implementations agree on the count (${v_count:-?})"
  else
    bad "${name}: implementations DISAGREE — verify.sh ${v_count:-?}, Dockerfile ${d_count:-?}"
  fi

  if [[ "${v_count}" == "${expect_count}" ]]; then
    ok "${name}: verify.sh counted ${expect_count}"
  else
    bad "${name}: verify.sh counted ${v_count:-?}, expected ${expect_count}"
  fi
  if [[ "${d_count}" == "${expect_count}" ]]; then
    ok "${name}: Dockerfile counted ${expect_count}"
  else
    bad "${name}: Dockerfile counted ${d_count:-?}, expected ${expect_count}"
  fi

  if [[ "${expect}" == "accept" ]]; then
    if (( v_rc == 0 )); then ok "${name}: verify.sh accepted"
    else bad "${name}: verify.sh rejected a valid bundle (rc=${v_rc})"; fi
    if (( d_rc == 0 )); then ok "${name}: Dockerfile accepted"
    else bad "${name}: Dockerfile rejected a valid bundle (rc=${d_rc})"; fi
  else
    if (( v_rc != 0 )) && grep -qF "${REJECT_MSG}" "${WORK}/last-verify-sh.log"; then
      ok "${name}: verify.sh rejected, on the threshold"
    elif (( v_rc != 0 )); then
      bad "${name}: verify.sh failed but NOT on the threshold — wrong reason"
    else
      bad "${name}: verify.sh ACCEPTED an under-signed bundle"
    fi

    if (( d_rc != 0 )) && grep -qF "${REJECT_MSG}" "${WORK}/last-dockerfile.log"; then
      ok "${name}: Dockerfile rejected, on the threshold"
    elif (( d_rc != 0 )); then
      bad "${name}: Dockerfile failed but NOT on the threshold — wrong reason"
    else
      bad "${name}: Dockerfile ACCEPTED an under-signed bundle"
    fi
  fi
}

echo
echo "=== threshold gate: ${THRESHOLD} distinct allowlisted signers required ==="

check_case "at-threshold"     "${F}/at-threshold.asc"     accept "${THRESHOLD}"
check_case "under-threshold"  "${F}/under-threshold.asc"  reject "$((THRESHOLD - 1))"
check_case "duplicate-signer" "${F}/duplicate-signer.asc" reject "$((THRESHOLD - 1))"
if [[ -f "${F}/unknown-padding.asc" ]]; then
  check_case "unknown-padding" "${F}/unknown-padding.asc" reject "$((THRESHOLD - 1))"
else
  echo
  note "SKIP unknown-padding: SHA256SUMS.asc carries no signature from an untrusted key"
fi

# --- cases needing a key the upstream bundle cannot supply ----------------

# Invariant 4, "importable is not trusted". This is the ONLY case that actually
# exercises the allowlist intersection. It cannot be built from upstream packets
# alone: keys/ deliberately holds exactly the allowlisted keys, so on real data
# the signer set and the allowlist are identical and the intersection is a no-op
# that could be deleted without any other test noticing. Here the throwaway key
# IS in the keyring — importable, verifiable, a genuine VALIDSIG — and is not on
# the allowlist. It must not count.
echo
echo "=== minting a throwaway signer (present in keyring, NOT allowlisted) ==="
untrusted_fpr="$(forge_signer untrusted "Untrusted Test Signer <untrusted@test.invalid>" none no)"
note "fingerprint ${untrusted_fpr}"
make_fixture "${F}/untrusted-in-keyring.asc" \
  "${ALLOWED_PKTS[@]:0:THRESHOLD-1}" "${WORK}/untrusted/sig.bin"
check_case "untrusted-in-keyring" "${F}/untrusted-in-keyring.asc" reject "$((THRESHOLD - 1))" \
  "${WORK}/untrusted/root/keys"

# The expired-key policy, decided 2026-09-20: a signature from a key that has
# since expired does not count, because the threshold is meant to measure people
# who CURRENTLY vouch for the bytes. gpg emits EXPKEYSIG *and* VALIDSIG for the
# same signature, so a parser reading only VALIDSIG counts it. All 10 allowlisted
# signers of 31.1 are current, so nothing in the real bundle exercises this — the
# EXPKEYSIG handling could be deleted from both gates and every other case here
# would still pass. This key is allowlisted on purpose: an expired key that is
# not allowlisted gets dropped by the intersection first, and the code path under
# test never runs.
echo
echo "=== minting a throwaway signer (allowlisted, then left to expire) ==="
expired_fpr="$(forge_signer expired "Expired Test Signer <expired@test.invalid>" seconds=2 yes)"
note "fingerprint ${expired_fpr}"
if wait_for_expiry "${WORK}/expired/root/keys/trusted-keyring.gpg" "${WORK}/expired/sig.bin"; then
  note "gpgv now reports EXPKEYSIG for it"
  make_fixture "${F}/expired-signer.asc" \
    "${ALLOWED_PKTS[@]:0:THRESHOLD-1}" "${WORK}/expired/sig.bin"
  check_case "expired-signer" "${F}/expired-signer.asc" reject "$((THRESHOLD - 1))" \
    "${WORK}/expired/root/keys"

  # And the other direction, which matters more than it looks. Put the expired
  # signature FIRST, followed by a full quorum of current ones: the bundle must
  # still be ACCEPTED, counting exactly the good signers.
  #
  # This is what holds the `NEWSIG` scoping in place. Both parsers clear their
  # `bad` flag on NEWSIG, which begins each signature block. Delete that reset
  # and `bad` latches on the first EXPKEYSIG and never clears, so every signature
  # AFTER an expired one is silently discarded too. With the expired packet last
  # — the obvious way to build the fixture — nothing follows it and the bug is
  # invisible; mutation testing found this suite could not see it.
  #
  # The real-world case is not hypothetical: the day one Core builder's key
  # lapses, a bundle like this is exactly what upstream ships, and a latched flag
  # would reject a release that ten current builders signed.
  make_fixture "${F}/expired-first.asc" \
    "${WORK}/expired/sig.bin" "${ALLOWED_PKTS[@]:0:THRESHOLD}"
  check_case "expired-first-then-quorum" "${F}/expired-first.asc" accept "${THRESHOLD}" \
    "${WORK}/expired/root/keys"
else
  bad "expired-signer: could not construct an expired signature"
fi

echo
echo "=============================================="
printf 'threshold tests: %d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 )) || exit 1
echo "OK — both implementations agree, and both fail closed"
