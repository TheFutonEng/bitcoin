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

# IMAGE_REVISION: Makefile default vs Dockerfile ARG. Drift here is invisible
# until someone pulls: the image would be PUBLISHED under one revision and
# LABELLED with another, and since the tag is not inside the artifact, the label
# is the only thing a consumer who pinned the digest can read.
mk_rev="$(sed -n 's/^REVISION[[:space:]]*?=[[:space:]]*\([0-9]\+\).*/\1/p' Makefile)"
df_rev="$(sed -n 's/^ARG IMAGE_REVISION=\([0-9]\+\).*/\1/p' Dockerfile)"
cmp_vals "IMAGE_REVISION" "${mk_rev}" "${df_rev}"

# RUNTIME_BASE: Makefile default vs Dockerfile ARG
mk_base="$(sed -n 's/^RUNTIME_BASE[[:space:]]*?=[[:space:]]*\(.*\)/\1/p' Makefile)"
df_base="$(sed -n 's/^ARG RUNTIME_BASE=\(.*\)/\1/p' Dockerfile)"
cmp_vals "RUNTIME_BASE" "${mk_base}" "${df_base}"

# EVERY base must be a digest, not a tag. That means the runtime base in both
# files AND the verifier base — the stage that actually checks the signatures,
# and therefore the one where a swapped image buys an attacker the most. It sat
# on a floating tag until 2026-09-20 because the invariant said "runtime base"
# and nobody re-read it against the Dockerfile.
#
# The buildkit image counts too, added 2026-09-22. It is not a base the image is
# built FROM, but it is the thing that assembles the layers, so an unpinned one
# can change the output digest with no change to this repository — which is the
# whole property `make verify-repro` asserts. Same class of input, same rule.
df_verifier="$(sed -n 's/^ARG VERIFIER_BASE=\(.*\)/\1/p' Dockerfile)"
mk_buildkit="$(sed -n 's/^BUILDKIT_IMAGE[[:space:]]*?*=[[:space:]]*\(.*\)$/\1/p' Makefile | head -1)"
pinned=1
for pair in "runtime/Dockerfile:${df_base}" "runtime/Makefile:${mk_base}" \
            "verifier/Dockerfile:${df_verifier}" "buildkit/Makefile:${mk_buildkit}"; do
  where="${pair%%:*}"; val="${pair#*:}"
  if [[ -z "${val}" ]]; then
    printf '  FAIL  %-18s could not read %s\n' "base pinning" "${where}"; pinned=0; fail=1
  elif [[ "${val}" != *"@sha256:"* ]]; then
    printf '  FAIL  %-18s %s is a tag, not a digest: %s\n' "base pinning" "${where}" "${val}"
    pinned=0; fail=1
  fi
done
(( pinned )) && printf '  OK    %-18s runtime, verifier and buildkit pinned by digest\n' "base pinning"

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
  allow_fprs="$(awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' \
                keys/trusted-fingerprints.txt | sort -u)"
  # Checked BOTH ways. Verifying only that every allowlisted key is present
  # leaves the keyring free to carry extras — which do not currently count,
  # because verification intersects with the textual allowlist, but an
  # unexplained key in the artifact the container build trusts is an
  # auditability hole even when it is inert. An external review flagged this as
  # one-way; it is not any more.
  #
  # The keyring legitimately contains SUBKEY fingerprints as well as primaries,
  # so "extra" means a PRIMARY key with no allowlist entry. Primaries are the
  # fpr line immediately following a pub record.
  kr_primaries="$(gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null \
                  | awk -F: '/^pub:/{want=1} /^fpr:/{if(want){print $10; want=0}}' | sort -u)"

  missing="$(comm -23 <(echo "${allow_fprs}") <(echo "${kr_primaries}"))"
  extra="$(comm -13 <(echo "${allow_fprs}") <(echo "${kr_primaries}"))"

  if [[ -n "${missing//[[:space:]]/}" || -n "${extra//[[:space:]]/}" ]]; then
    while read -r f; do
      [[ -n "$f" ]] && printf '  FAIL  %-18s %s allowlisted but not in the keyring\n' "keyring sync" "$f"
    done <<< "${missing}"
    while read -r f; do
      [[ -n "$f" ]] && printf '  FAIL  %-18s %s in the keyring but NOT allowlisted\n' "keyring sync" "$f"
    done <<< "${extra}"
    fail=1
  else
    printf '  OK    %-18s keyring primaries == allowlist, both ways\n' "keyring sync"
  fi
fi

# A committed private signing key is unrecoverable: it is in the history, in
# every clone, and on GitHub. .gitignore does not prevent `git add -f`, and does
# nothing about a key committed before the rule existed. This is the check that
# actually holds.
if git rev-parse --git-dir >/dev/null 2>&1; then
  # The needle is assembled at runtime so this file does not match its own
  # pattern — the first version of this check cheerfully reported itself.
  needle="PRIVATE"" KEY"
  leaked="$(git ls-files -z 2>/dev/null | xargs -0 grep -lI -- "${needle}" 2>/dev/null || true)"
  leaked="$(printf '%s\n%s\n' "${leaked}" \
              "$(git ls-files '*.key' 'cosign.key' 2>/dev/null || true)" \
            | grep -v '^$' | sort -u || true)"
  if [[ -n "${leaked//[[:space:]]/}" ]]; then
    while read -r f; do
      [[ -n "$f" ]] && printf '  FAIL  %-18s %s is TRACKED and looks like a private key\n' "secrets" "$f"
    done <<< "${leaked}"
    fail=1
  else
    printf '  OK    %-18s no private key material is tracked\n' "secrets"
  fi
fi

echo
if (( fail )); then
  echo "FAIL — values disagree, base is unpinned, or the keyring does not match" >&2
  exit 1
fi
echo "OK — duplicated values agree"
