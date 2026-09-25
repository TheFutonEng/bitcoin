# syntax=docker/dockerfile:1.7
#
# Bitcoin Core container with build-time provenance enforcement.
#
# Design invariants (do not relax without a deliberate decision):
#   1. The build NEVER touches the network. Everything comes from upstream/,
#      which is populated and reviewed out of band by scripts/fetch-release.sh.
#   2. The release tarball is admitted only if SHA256SUMS carries at least
#      MIN_GOOD_SIGS valid detached signatures from allowlisted keys, AND the
#      tarball's sha256 matches its line in SHA256SUMS. Verification uses gpgv
#      against a committed keyring — no package install, no network.
#   3. The set of acceptable signing keys is an explicit, hand-reviewed
#      allowlist (keys/trusted-fingerprints.txt), not "whatever a keyserver
#      handed us at build time".
#   4. Runtime image has no shell, no package manager, and runs as non-root.

ARG BITCOIN_VERSION=31.1
# The image revision for that Bitcoin version, Debian-style: same upstream
# binaries, different packaging. The published tag and
# org.opencontainers.image.version are both BITCOIN_VERSION-IMAGE_REVISION.
#
# This lives here AND as REVISION in the Makefile; check-pins.sh asserts they
# agree, exactly as it does for MIN_GOOD_SIGS. The default matters: a direct
# `docker build` that forgets the build arg still produces a correctly labelled
# image rather than one claiming to be "31.1-".
ARG IMAGE_REVISION=3
# Invariant 4: pinned by digest, never by tag. This digest IS the `:nonroot`
# variant of cc-debian12 as of 2026-09-12 — the name no longer says so, which
# is the cost of pinning. It is an OCI image index (amd64, arm64/v8, arm/v7,
# s390x), so multi-arch still works. To bump: re-resolve the tag, update here
# AND in the Makefile, then re-run `make smoke verify-image verify-contents`.
ARG RUNTIME_BASE=gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
# Pinned by digest, like the runtime base. This stage is where signatures are
# actually verified, so a compromised or silently-updated base here is worse
# than one in the runtime image: a `gpgv` that emits fabricated VALIDSIG lines
# would defeat the threshold check entirely, and the resulting image would look
# perfectly legitimate. It was left on a floating tag until 2026-09-20 because
# invariant 5 said "runtime base" and nobody re-read it against this line.
# OCI index (amd64, arm64/v8, arm/v7), so multi-arch survives the pin — though
# see the --platform note on the stage below: only the BUILD host's variant is
# ever used.
ARG VERIFIER_BASE=debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

# ---------------------------------------------------------------------------
# Stage 1: verify + unpack
# ---------------------------------------------------------------------------
#
# Runs on the BUILD platform, not the target. Nothing this stage does is
# architecture-specific — gpgv, sha256sum, tar and install produce the same
# bytes whichever CPU runs them — so an arm64 image is verified by a native
# gpgv on the build host rather than by one running under QEMU. That keeps the
# gate that matters most off an emulator, and means cross-building needs no
# binfmt at all. The TARGET's binaries are only ever copied, never executed.
FROM --platform=${BUILDPLATFORM} ${VERIFIER_BASE} AS verifier

ARG BITCOIN_VERSION
# The target architecture selects the tarball. This is the ONLY place the
# arch-to-triple mapping lives for the build, and it has to live here rather
# than in a --build-arg: a single `buildx build --platform linux/amd64,linux/arm64`
# cannot pass a different build arg to each platform, so a TARGET_TRIPLE arg
# would have put the amd64 tarball into the arm64 image. It was an ARG until
# 2026-09-25, when only one architecture was ever built.
#
# An unmapped architecture fails the build rather than falling back to a
# default. Adding one means adding it here, confirming the tarball layout
# (see the unpack note below), and giving it a reproducible digest.
ARG TARGETARCH
# Bitcoin Core release SHA256SUMS files typically carry 10+ builder signatures.
# 6 matches the `--min-good-sigs 6` that bitcoin/bitcoin's CI passes to Core's
# verify.py, so this build is no weaker than the widely used image. Raise it if
# you want. Do not set this to 1.
ARG MIN_GOOD_SIGS=6
# Binaries to ship. Keep this list minimal — every binary is attack surface.
# NOTE: Core 30.x+ may also ship a unified `bitcoin` wrapper binary. Run
# `tar -tzf upstream/<tarball> | grep /bin/` before assuming what exists.
ARG SHIP_BINARIES="bitcoind bitcoin-cli"

# No package installation. debian:bookworm-slim already ships /usr/bin/gpgv,
# tar and coreutils, which is everything this stage needs. An `apt-get` here
# would require the network that invariant 1 forbids — and did, until
# 2026-09-14: the build failed at this step with exit 100 and had never once
# succeeded.

WORKDIR /stage

# Staged upstream artifacts only. SHA256SUMS and its signature are committed;
# the tarball is fetched by `make fetch` and gitignored. Nothing comes from
# the network during the build itself.
#
# A glob, because the triple is only known inside a RUN. It picks up every
# staged linux-gnu tarball; the digest check below selects the one for this
# target and checks it against the signed sums, and the others never leave this
# throwaway stage. If none is staged the COPY itself fails.
COPY upstream/SHA256SUMS upstream/SHA256SUMS.asc ./
COPY upstream/bitcoin-${BITCOIN_VERSION}-*-linux-gnu.tar.gz ./
COPY keys/ ./keys/

# --- signature threshold check -------------------------------------------
# gpgv, not gpg: it verifies a detached signature against a fixed keyring and
# cannot import, fetch or be steered by trust settings — which is exactly the
# job. keys/trusted-keyring.gpg is generated by scripts/build-keyring.sh from
# the same keys/*.asc the host tooling uses; check-pins.sh asserts the two agree.
# gpgv exits non-zero whenever any signature fails, so its status output is
# parsed rather than its exit code (see the gotcha in CLAUDE.md).
RUN set -eux; \
    gpgv --keyring ./keys/trusted-keyring.gpg --status-fd 1 \
         SHA256SUMS.asc SHA256SUMS \
        > /stage/gpg-status.txt 2>/stage/gpg-stderr.txt || true; \
    \
    # Primary-key fingerprints that produced a valid signature. Field 3 is the
    # signing SUBKEY when a builder signs with one, and the allowlist holds
    # PRIMARY fingerprints — matching $3 silently drops those (7 of 11 on 31.1).
    # The last field is the primary fpr. Keep this identical to verify.sh.
    awk '/^\[GNUPG:\] NEWSIG/ {bad=0} /^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG)/ {bad=1} /^\[GNUPG:\] VALIDSIG/ {if(!bad) print (NF >= 12 ? $NF : $3)}' /stage/gpg-status.txt \
      | sort -u > /stage/signers.txt; \
    \
    # Intersect with the hand-reviewed allowlist. A key being importable is not
    # the same as a key being trusted; this is the line that enforces that.
    awk '{sub(/#.*/,""); gsub(/[[:space:]]/,""); if (length) print toupper($0)}' ./keys/trusted-fingerprints.txt | sort -u > /stage/allowed.txt; \
    comm -12 /stage/signers.txt /stage/allowed.txt > /stage/accepted-signers.txt; \
    good="$(wc -l < /stage/accepted-signers.txt)"; \
    \
    echo "=== signatures accepted: ${good} (minimum ${MIN_GOOD_SIGS}) ==="; \
    cat /stage/accepted-signers.txt; \
    if [ "${good}" -lt "${MIN_GOOD_SIGS}" ]; then \
      echo "FATAL: signature threshold not met" >&2; \
      cat /stage/gpg-stderr.txt >&2; \
      exit 1; \
    fi

# --- digest check ---------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) triple=x86_64-linux-gnu ;; \
      arm64) triple=aarch64-linux-gnu ;; \
      *) echo "FATAL: no tarball mapping for TARGETARCH='${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    tarball="bitcoin-${BITCOIN_VERSION}-${triple}.tar.gz"; \
    test -f "${tarball}" || { \
      echo "FATAL: ${tarball} is not staged — run: make fetch-tarball PLATFORM=linux/${TARGETARCH}" >&2; \
      exit 1; }; \
    echo "${tarball}" > /stage/tarball-name.txt; \
    grep "  ${tarball}\$" SHA256SUMS > tarball.sha256; \
    test -s tarball.sha256; \
    sha256sum -c tarball.sha256; \
    sha256sum "${tarball}" | cut -d' ' -f1 > /stage/upstream-digest.txt

# --- unpack ---------------------------------------------------------------
# Verified 2026-09-13 against the real 31.1 tarball: it ships bin/, libexec/ and
# share/ but NO lib/, and `bitcoind` is a standalone binary linking only glibc —
# no libbitcoinkernel.so. Nothing from libexec/ is needed either. If a future
# release changes that, `make smoke` is what catches it.
RUN set -eux; \
    mkdir -p /out/bin /unpack /out/datadir; \
    tar -xzf "$(cat /stage/tarball-name.txt)" \
        --strip-components=1 -C /unpack; \
    for b in ${SHIP_BINARIES}; do \
      install -m 0755 "/unpack/bin/${b}" "/out/bin/${b}"; \
    done; \
    cp /stage/accepted-signers.txt /stage/upstream-digest.txt /out/

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${RUNTIME_BASE} AS runtime

ARG BITCOIN_VERSION
# Re-declared inside the stage for the same reason as RUNTIME_BASE below: a
# global ARG is invisible inside a stage, so without this the version label
# would silently expand to "31.1-" and every published image would be
# mislabelled. That exact bug shipped once already.
ARG IMAGE_REVISION
# RUNTIME_BASE must be re-declared here. A global ARG above the first FROM is
# visible to FROM instructions but NOT inside a stage, so without this the
# base.name label silently expands to "" — which is what shipped in PR #2 and
# broke verify-contents.sh's base resolution entirely.
ARG RUNTIME_BASE
ARG SOURCE_REPO="https://example.invalid/REPLACE-ME"
ARG VCS_REF="unknown"
ARG BUILD_DATE="1970-01-01T00:00:00Z"

LABEL org.opencontainers.image.title="bitcoin" \
      org.opencontainers.image.description="Bitcoin Core daemon, built from signature-verified upstream release binaries" \
      org.opencontainers.image.version="${BITCOIN_VERSION}-${IMAGE_REVISION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="${SOURCE_REPO}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="${RUNTIME_BASE}"

COPY --from=verifier /out/bin/ /usr/local/bin/
# Provenance breadcrumbs, readable from inside the image and by `docker cp`.
COPY --from=verifier /out/accepted-signers.txt /out/upstream-digest.txt /usr/local/share/bitcoind-provenance/

# An EMPTY directory, present in the image and owned by the runtime user.
#
# Docker seeds a fresh named or anonymous volume from whatever is at the mount
# point in the image, ownership included. /data does not exist in the distroless
# base, so before this every volume came up root-owned and `docker run` — with no
# arguments and no mount at all, the first command anyone tries — died with
# "Unable to open settings file /data/settings.json.tmp for writing".
#
# There is no shell here, so the usual fix of chown-ing in an entrypoint script
# is not available, and adding one would undo the reason this image is
# distroless. Creating the directory at build time is the only mechanism left.
#
# This does NOT help a bind mount: a host directory keeps its own ownership, so
# `chown 65532:65532` on the host is still required and still documented. Under
# Kubernetes it is also moot, because securityContext.fsGroup chowns the volume
# at mount time. It buys the standalone-container case, which is a real one.
COPY --from=verifier --chown=65532:65532 /out/datadir /data

# BITCOIN_DATA is deliberately absent. It was here until 2026-09-23 and did
# nothing: bitcoind does not read it. It is a convention from bitcoin/bitcoin,
# whose ENTRYPOINT SCRIPT expands it into -datadir=. This image has no script by
# design, so the variable was pure decoration that both READMEs listed as though
# setting it would work. Verified inert by running with BITCOIN_DATA=/elsewhere:
# the datadir did not move.

# distroless nonroot
USER 65532:65532

VOLUME ["/data"]

# mainnet RPC / P2P / ZMQ block / ZMQ tx
EXPOSE 8332 8333 28332 28333

# The flags belong to ENTRYPOINT, not CMD, and the difference is not cosmetic.
# Docker REPLACES CMD with user arguments but PREPENDS ENTRYPOINT to them. With
# `CMD ["-datadir=/data", ...]`, any argument a consumer passed silently dropped
# the datadir: `docker run -v vol:/data image -txindex=1` wrote the chain to
# /home/nonroot/.bitcoin on the container layer, ignored the mounted volume, and
# started normally. A node that looks healthy and loses its data on --rm.
#
# Both flags remain overridable, which was the obvious objection and was
# measured: Bitcoin Core takes the LAST duplicate on the command line, so
# `-datadir=/other` still wins, and `-noprinttoconsole` still silences it.
ENTRYPOINT ["/usr/local/bin/bitcoind", "-datadir=/data", "-printtoconsole"]
# Empty on purpose. The distroless base sets no CMD, so leaving this out would
# work by accident; stating it means a future base that DOES set one cannot
# append junk to our argv.
CMD []
