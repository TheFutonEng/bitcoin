#!/usr/bin/env bash
#
# Move the repo to a new upstream Bitcoin Core version, ready for review.
#
# Every bump before this one was a REVISION bump of 31.1; the version itself had
# never moved, and the steps for it lived in prose. This does the mechanical
# parts in a fixed order and stops at the first one that needs a human:
#
#   1. Preconditions: clean tree; NEW is a version and differs from the current.
#   2. The runtime library contract, BEFORE anything is changed. Upstream's
#      contrib/guix/symbol-check.py lists every shared library a release binary
#      may load (ELF_ALLOWED_LIBRARIES). The runtime base provides exactly
#      glibc and no more, so a change there means the base may need to change
#      too, and that is a decision, not a sed. A changed contract stops here.
#      `make build` runs check-runtime-deps against the real binaries anyway;
#      this is the early warning, with the reason attached.
#   3. Rewrite every copy of the version, and reset REVISION to 1: the first
#      packaging of NEW. check-pins.sh asserts afterwards that they all agree.
#   4. `make fetch` per platform: signed sums from bitcoincore.org (or rebuilt
#      from guix.sigs), the signature threshold, and Core's verify.py as a
#      second opinion. A release that does not clear the threshold stops here.
#   5. `make repro-digest-write`: the canonical digest per platform, which CI
#      checks on every PR. This builds both platforms (arm64 cross-built).
#
# It commits nothing. Review `git diff`, then commit on a branch.
#
#   usage: scripts/bump-version.sh <new-version>        e.g. 31.2
#
# env:
#   SKIP_REPRO=1   skip step 5 (no local docker); CI's verify-repro will then
#                  fail until reproducible-digest.txt is written by someone.
#
set -euo pipefail

NEW="${1:?usage: bump-version.sh <new-version>, e.g. 31.2}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say()  { printf '\n>> %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- 1. preconditions -----------------------------------------------------------
[[ "${NEW}" =~ ^[0-9]+\.[0-9]+$ ]] || die "'${NEW}' is not a Core version like 31.2"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean; commit or stash first"
OLD="$(make -s print-version)"
[[ "${NEW}" != "${OLD}" ]] || die "already at ${OLD}"
[[ "$(printf '%s\n%s\n' "${OLD}" "${NEW}" | sort -V | tail -1)" == "${NEW}" ]] \
  || die "${NEW} is older than ${OLD}; releasing an older line is not what this script is for"
major_change=0; [[ "${OLD%%.*}" == "${NEW%%.*}" ]] || major_change=1
say "bumping Bitcoin Core ${OLD} -> ${NEW}$( ((major_change)) && echo '  (MAJOR version change)')"

# --- 2. runtime library contract, before touching anything -----------------------
contract() { # <tag>
  curl -sSfL --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/bitcoin/bitcoin/$1/contrib/guix/symbol-check.py" \
    | awk '/^ELF_ALLOWED_LIBRARIES/,/^}/'
}
say "runtime library contract: v${OLD} vs v${NEW} (contrib/guix/symbol-check.py)"
old_c="$(contract "v${OLD}")" || die "could not fetch symbol-check.py at v${OLD}"
new_c="$(contract "v${NEW}")" || die "could not fetch symbol-check.py at v${NEW}"
[[ -n "${old_c}" && -n "${new_c}" ]] || die "ELF_ALLOWED_LIBRARIES not found; upstream moved it, read symbol-check.py by hand"
if [[ "${old_c}" != "${new_c}" ]]; then
  diff <(echo "${old_c}") <(echo "${new_c}") || true
  die "ELF_ALLOWED_LIBRARIES changed between v${OLD} and v${NEW}. Decide whether RUNTIME_BASE still provides every library before bumping."
fi
echo "   unchanged ($(grep -c "'" <<<"${new_c}") entries)"

# --- 3. rewrite every copy of the version ---------------------------------------------
say "rewriting version ${OLD} -> ${NEW}, REVISION -> 1"
o="${OLD//./\\.}"
sed -i -E "s/^(VERSION[[:space:]]*\\?=[[:space:]]*)${o}\$/\\1${NEW}/"       Makefile
sed -i -E "s/^(REVISION[[:space:]]*\\?=[[:space:]]*)[0-9]+\$/\\11/"          Makefile
sed -i -E "s/^ARG BITCOIN_VERSION=${o}\$/ARG BITCOIN_VERSION=${NEW}/"         Dockerfile
sed -i -E "s/^ARG IMAGE_REVISION=[0-9]+\$/ARG IMAGE_REVISION=1/"              Dockerfile
# Fallback defaults in scripts that make normally passes VERSION to.
sed -i -E "s/^(VERSION=\"\\\$\\{[12]:-)${o}(\\}\")/\\1${NEW}\\2/" \
  tests/test-threshold.sh scripts/verify-contents.sh scripts/verify-image.sh
sed -i -E "s/^(VERSION=\"\\\$\\{VERSION:-)${o}(\\}\")/\\1${NEW}\\2/"         scripts/verify-reproducible.sh
[[ "$(make -s print-version)" == "${NEW}" && "$(make -s print-revision)" == 1 ]] \
  || die "Makefile did not take the new version; fix by hand"

# --- 4. fetch and verify, per platform -------------------------------------------------
for p in $(make -s print-platforms); do
  say "make fetch VERSION=${NEW} PLATFORM=${p}"
  make fetch VERSION="${NEW}" PLATFORM="${p}"
done
grep -q "  bitcoin-${NEW}-" upstream/SHA256SUMS || die "upstream/SHA256SUMS does not list ${NEW}"

say "make check-pins"
make -s check-pins

# --- 5. canonical reproducible digest ----------------------------------------------------
if [[ "${SKIP_REPRO:-}" == 1 ]]; then
  say "SKIP_REPRO=1: reproducible-digest.txt NOT updated; CI will fail until it is"
else
  say "make repro-digest-write (builds every platform)"
  make repro-digest-write
fi

say "done. Review, then commit on a branch:"
git status --short
cat <<EOF

   Check before committing:
   - git diff: only version strings, REVISION=1, upstream/SHA256SUMS(.asc),
     reproducible-digest.txt
   - release notes: https://bitcoincore.org/en/releases/${NEW}/
     (anything that changes defaults, config, or the files shipped)
$( ((major_change)) && printf '   - MAJOR version: read the notes for removed options and changed defaults;\n     examples/bitcoin.conf and tests/test-config.sh may need updating\n')
   Commit:
     git switch -c bump-${NEW}
     git commit -am "upstream: bitcoin core ${NEW}, image revision 1"
EOF
