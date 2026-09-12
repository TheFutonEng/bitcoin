#!/usr/bin/env bash
#
# Bootstrap keys/ from the Bitcoin Core guix.sigs builder-keys directory.
#
# WHY THIS SOURCE: guix.sigs is where Core's own release verification tooling
# (contrib/verify-binaries/verify.py) points for builder keys. Keys arrive here
# as files in a git repo, which means every addition or rotation is a reviewable
# commit with an author and a date. That is a meaningfully better starting point
# than asking a keyserver for a fingerprint and trusting what comes back.
#
# It is still a bootstrap, not a trust anchor. The clone happens over HTTPS from
# GitHub. What makes the result trustworthy is the review step below, not this
# script.
#
# Intended workflow:
#   1. Run this ONCE.
#   2. Review keys/trusted-fingerprints.txt.candidate. For each fingerprint,
#      corroborate from a second source: git history on the key file
#      (`git -C <clone> log --follow builder-keys/<name>`), the developer's own
#      published fingerprint, keys you already hold from prior verifications,
#      release announcements. A key added to guix.sigs last week by an account
#      you have never seen is a question, not a formality.
#   3. Delete what you cannot corroborate. Commit the rest.
#   4. Do not run this again unqualified. Adding a signer later should be a
#      single-key commit with the reason in the message.
#
#   usage: scripts/import-builder-keys.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS="${REPO_ROOT}/keys"
GUIX_SIGS_URL="${GUIX_SIGS_URL:-https://github.com/bitcoin-core/guix.sigs.git}"

mkdir -p "${KEYS}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo ">> cloning guix.sigs (full history — the history is the review material)"
git clone --quiet --filter=blob:none "${GUIX_SIGS_URL}" "${tmp}/guix.sigs"

GUIX_COMMIT="$(git -C "${tmp}/guix.sigs" rev-parse HEAD)"
KEYDIR="${tmp}/guix.sigs/builder-keys"
[[ -d "${KEYDIR}" ]] || { echo "builder-keys/ not found — layout changed upstream, adapt this script" >&2; exit 1; }

export GNUPGHOME="${tmp}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

declare -A OWNER=()
imported=0

shopt -s nullglob
for kf in "${KEYDIR}"/*; do
  [[ -f "${kf}" ]] || continue
  name="$(basename "${kf}")"
  name="${name%.gpg}"; name="${name%.asc}"; name="${name%.pgp}"

  # Which fingerprints does this file contain?
  fprs="$(gpg --batch --quiet --with-colons --import-options show-only --import "${kf}" 2>/dev/null \
          | awk -F: '/^fpr:/ {print $10}' | head -n 1 || true)"
  [[ -n "${fprs}" ]] || { echo "  SKIP    ${name} (unparseable)"; continue; }

  gpg --batch --quiet --import "${kf}" 2>/dev/null || { echo "  SKIP    ${name} (import failed)"; continue; }

  for fpr in ${fprs}; do
    gpg --batch --armor --export "${fpr}" > "${KEYS}/${fpr}.asc"
    if [[ -s "${KEYS}/${fpr}.asc" ]]; then
      OWNER["${fpr}"]="${name}"
      echo "  import  ${fpr}  ${name}"
      imported=$((imported + 1))
    else
      rm -f "${KEYS}/${fpr}.asc"
    fi
  done
done

{
  echo "# Bitcoin Core release signing keys this build will accept."
  echo "#"
  echo "# Bootstrapped $(date -u +%Y-%m-%d) from guix.sigs @ ${GUIX_COMMIT}"
  echo "# EVERY LINE BELOW NEEDS HUMAN REVIEW. Delete what you cannot corroborate."
  echo "#"
  echo "# To review a key's provenance:"
  echo "#   git clone ${GUIX_SIGS_URL} && cd guix.sigs"
  echo "#   git log --follow --format='%ad %an %s' -- builder-keys/<name>"
  echo
  for fpr in "${!OWNER[@]}"; do
    printf '%s  # %s\n' "${fpr}" "${OWNER[$fpr]}"
  done | sort
} > "${KEYS}/trusted-fingerprints.txt.candidate"

echo
echo "imported ${imported} keys from guix.sigs @ ${GUIX_COMMIT}"
echo "candidate allowlist: keys/trusted-fingerprints.txt.candidate"
echo
echo "Review it, then:  mv keys/trusted-fingerprints.txt{.candidate,}"
