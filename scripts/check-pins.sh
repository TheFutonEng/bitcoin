#!/usr/bin/env bash
#
# Assert that values duplicated across the Dockerfile, Makefile and verify.sh
# actually agree, and that the keyring backs the allowlist.
#
# Invariant 5 says verification logic lives in two places on purpose. The cost
# of that decision is drift: someone raises MIN_GOOD_SIGS in the Makefile, the
# Dockerfile keeps the old value, and the image build silently enforces a weaker
# rule than CI does. Same for the runtime base digest. This is the cheap check
# that makes the duplication safe.
#
#   usage: scripts/check-pins.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

fail=0
cmp_vals() {
  local label="$1"; shift
  local first="$1" ok=1
  for v in "$@"; do [[ "${v}" == "${first}" ]] || ok=0; done
  if (( ok )); then
    printf '  OK    %-18s %s\n' "${label}" "${first}"
  else
    printf '  DRIFT %-18s %s\n' "${label}" "$*"
    fail=1
  fi
}

# MIN_GOOD_SIGS: Makefile default, Dockerfile ARG, verify.sh fallback
mk_sigs="$(sed -n 's/^MIN_GOOD_SIGS[[:space:]]*?=[[:space:]]*\([0-9]\+\).*/\1/p' Makefile)"
df_sigs="$(sed -n 's/^ARG MIN_GOOD_SIGS=\([0-9]\+\).*/\1/p' Dockerfile)"
vs_sigs="$(sed -n 's/.*MIN_GOOD_SIGS:-\([0-9]\+\)}.*/\1/p' scripts/verify.sh)"
cmp_vals "MIN_GOOD_SIGS" "${mk_sigs}" "${df_sigs}" "${vs_sigs}"

# RUNTIME_BASE: Makefile default vs Dockerfile ARG
mk_base="$(sed -n 's/^RUNTIME_BASE[[:space:]]*?=[[:space:]]*\(.*\)/\1/p' Makefile)"
df_base="$(sed -n 's/^ARG RUNTIME_BASE=\(.*\)/\1/p' Dockerfile)"
cmp_vals "RUNTIME_BASE" "${mk_base}" "${df_base}"

# Invariant 4: that base must be a digest, not a tag — in BOTH files. Checking
# only one of them reports OK while the other is still on a floating tag.
inv4=1
for pair in "Dockerfile:${df_base}" "Makefile:${mk_base}"; do
  where="${pair%%:*}"; val="${pair#*:}"
  [[ "${val}" == *"@sha256:"* ]] || {
    printf '  FAIL  %-18s %s has a tag, not a digest: %s\n' "invariant 4" "${where}" "${val}"
    inv4=0; fail=1; }
done
(( inv4 )) && printf '  OK    %-18s pinned by digest in both files\n' "invariant 4"

# Every allowlisted fingerprint needs its public key present, or gpg cannot
# verify that builder's signature and the fingerprint sits in the allowlist
# doing nothing. The symptom is silent: the accepted count just comes out lower,
# with no line naming the missing file. Verified 2026-09-13 by deleting one key
# file — the count dropped 10 -> 9 and verify.sh still exited 0.
missing=0; n_allow=0
while read -r fpr; do
  [[ -n "${fpr}" ]] || continue
  n_allow=$((n_allow+1))
  [[ -f "keys/${fpr}.asc" ]] || {
    printf '  FAIL  %-18s allowlisted but keys/%s.asc is absent\n' "keyring" "${fpr}"
    missing=1; fail=1; }
done < <(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' \
         keys/trusted-fingerprints.txt)
(( missing )) || printf '  OK    %-18s all %d allowlisted keys present\n' "keyring" "${n_allow}"

# keys/trusted-keyring.gpg is DERIVED from keys/*.asc and is what the container
# build actually verifies against (gpgv cannot import, so it needs a keyring).
# If it drifts from the allowlist, the image build and the host check stop
# agreeing — the exact split invariant 6 exists to prevent. Compare the keys the
# keyring actually contains against the allowlist, rather than byte-comparing a
# regenerated file, which would churn across gpg versions.
KEYRING="keys/trusted-keyring.gpg"
if [[ ! -f "${KEYRING}" ]]; then
  printf '  FAIL  %-18s %s is absent — run scripts/build-keyring.sh\n' "keyring file" "${KEYRING}"
  fail=1
else
  kr_fprs="$(gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null \
             | awk -F: '/^fpr:/ && !seen[$10]++ {print $10}' | sort -u)"
  allow_fprs="$(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' \
                keys/trusted-fingerprints.txt | sort -u)"
  # The keyring carries subkey fingerprints too; only primaries must correspond.
  extra="$(comm -23 <(echo "${allow_fprs}") <(echo "${kr_fprs}"))"
  if [[ -n "${extra}" ]]; then
    while read -r f; do
      [[ -n "$f" ]] && printf '  FAIL  %-18s %s allowlisted but not in the keyring\n' "keyring" "$f"
    done <<< "${extra}"
    fail=1
  else
    printf '  OK    %-18s every allowlisted key is in %s\n' "keyring sync" "${KEYRING##*/}"
  fi
fi

echo
if (( fail )); then
  echo "FAIL — values disagree, base is unpinned, or the keyring does not match" >&2
  exit 1
fi
echo "OK — duplicated values agree"
