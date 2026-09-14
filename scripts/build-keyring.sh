#!/usr/bin/env bash
#
# Build keys/trusted-keyring.gpg from the armored keys in keys/.
#
# WHY THIS EXISTS: the container build has no network (invariant 1), so it cannot
# `apt-get install gnupg`. `debian:bookworm-slim` already ships `/usr/bin/gpgv`,
# which is purpose-built for verifying a detached signature against a fixed
# keyring — but gpgv takes a binary keyring, not armored .asc files, and cannot
# import. So the keyring is built here, on the host, and committed.
#
# The keyring is DERIVED, not a source of truth. keys/*.asc are the source; this
# is a mechanical re-encoding of them. Regenerate and diff to review it:
#
#   scripts/build-keyring.sh && git diff --stat keys/trusted-keyring.gpg
#
# gpgv ignores trust entirely and only checks signatures against the keyring.
# That suits us: trust is the fingerprint allowlist, applied afterwards by
# intersecting against keys/trusted-fingerprints.txt. Keeping both means a key
# present in the keyring still does not count unless it is also allowlisted —
# which is invariant 4, and what check-pins.sh enforces.
#
#   usage: scripts/build-keyring.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS="${REPO_ROOT}/keys"
OUT="${KEYS}/trusted-keyring.gpg"

shopt -s nullglob
keyfiles=("${KEYS}"/*.asc)
(( ${#keyfiles[@]} > 0 )) || { echo "no .asc files in keys/" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT

gpg --batch --quiet --import "${keyfiles[@]}"

# Deterministic output: export in a fixed fingerprint order so regenerating on a
# different machine produces the same bytes and `git diff` stays meaningful.
mapfile -t fprs < <(printf '%s\n' "${keyfiles[@]}" \
  | xargs -n1 basename | sed 's/\.asc$//' | tr 'a-f' 'A-F' | sort)

gpg --batch --export "${fprs[@]}" > "${OUT}"
[[ -s "${OUT}" ]] || { echo "export produced an empty keyring" >&2; exit 1; }

echo "wrote ${OUT#"${REPO_ROOT}/"}  ($(stat -c%s "${OUT}") bytes, ${#fprs[@]} keys)"
printf '  %s\n' "${fprs[@]}"
