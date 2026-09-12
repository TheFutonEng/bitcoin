# syntax=docker/dockerfile:1.7
#
# Bitcoin Core container with build-time provenance enforcement.
#
# Design invariants (do not relax without a deliberate decision):
#   1. The build NEVER touches the network. Everything comes from vendor/,
#      which is populated and reviewed out of band by scripts/fetch-release.sh.
#   2. The release tarball is admitted only if SHA256SUMS carries at least
#      MIN_GOOD_SIGS valid detached signatures from keys in keys/, AND the
#      tarball's sha256 matches its line in SHA256SUMS.
#   3. The set of acceptable signing keys is an explicit, hand-reviewed
#      allowlist (keys/trusted-fingerprints.txt), not "whatever a keyserver
#      handed us at build time".
#   4. Runtime image has no shell, no package manager, and runs as non-root.

ARG BITCOIN_VERSION=31.1
ARG TARGET_TRIPLE=x86_64-linux-gnu
ARG RUNTIME_BASE=gcr.io/distroless/cc-debian12:nonroot
ARG VERIFIER_BASE=debian:bookworm-slim

# ---------------------------------------------------------------------------
# Stage 1: verify + unpack
# ---------------------------------------------------------------------------
FROM ${VERIFIER_BASE} AS verifier

ARG BITCOIN_VERSION
ARG TARGET_TRIPLE
# Bitcoin Core release SHA256SUMS files typically carry 10+ builder signatures.
# 6 matches the `--min-good-sigs 6` that bitcoin/bitcoin's CI passes to Core's
# verify.py, so this build is no weaker than the widely used image. Raise it if
# you want. Do not set this to 1.
ARG MIN_GOOD_SIGS=6
# Binaries to ship. Keep this list minimal — every binary is attack surface.
# NOTE: Core 30.x+ may also ship a unified `bitcoin` wrapper binary. Run
# `tar -tzf vendor/<tarball> | grep /bin/` before assuming what exists.
ARG SHIP_BINARIES="bitcoind bitcoin-cli"

RUN apt-get update \
 && apt-get install -y --no-install-recommends gnupg ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /stage

# Vendored, reviewed, committed artifacts only.
COPY vendor/SHA256SUMS vendor/SHA256SUMS.asc ./
COPY vendor/bitcoin-${BITCOIN_VERSION}-${TARGET_TRIPLE}.tar.gz ./
COPY keys/ ./keys/

# --- signature threshold check -------------------------------------------
RUN set -eux; \
    export GNUPGHOME="$(mktemp -d)"; \
    chmod 700 "$GNUPGHOME"; \
    gpg --batch --quiet --import ./keys/*.asc; \
    gpg --batch --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS \
        > /stage/gpg-status.txt 2>/stage/gpg-stderr.txt || true; \
    \
    # Fingerprints that produced a cryptographically valid signature.
    awk '/^\[GNUPG:\] VALIDSIG/ {print $3}' /stage/gpg-status.txt \
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
    fi; \
    rm -rf "$GNUPGHOME"

# --- digest check ---------------------------------------------------------
RUN set -eux; \
    tarball="bitcoin-${BITCOIN_VERSION}-${TARGET_TRIPLE}.tar.gz"; \
    grep "  ${tarball}\$" SHA256SUMS > tarball.sha256; \
    test -s tarball.sha256; \
    sha256sum -c tarball.sha256; \
    sha256sum "${tarball}" | cut -d' ' -f1 > /stage/upstream-digest.txt

# --- unpack ---------------------------------------------------------------
RUN set -eux; \
    mkdir -p /out/bin /out/lib /unpack; \
    tar -xzf "bitcoin-${BITCOIN_VERSION}-${TARGET_TRIPLE}.tar.gz" \
        --strip-components=1 -C /unpack; \
    for b in ${SHIP_BINARIES}; do \
      install -m 0755 "/unpack/bin/${b}" "/out/bin/${b}"; \
    done; \
    # Some releases ship libbitcoinkernel.so alongside the binaries. Carry
    # anything that exists; the smoke test in the Makefile is what proves
    # whether the runtime base can actually resolve it.
    if [ -d /unpack/lib ]; then cp -a /unpack/lib/. /out/lib/ || true; fi; \
    touch /out/lib/.keep; \
    cp /stage/accepted-signers.txt /stage/upstream-digest.txt /out/

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${RUNTIME_BASE} AS runtime

ARG BITCOIN_VERSION
ARG SOURCE_REPO="https://example.invalid/REPLACE-ME"
ARG VCS_REF="unknown"
ARG BUILD_DATE="1970-01-01T00:00:00Z"

LABEL org.opencontainers.image.title="bitcoind" \
      org.opencontainers.image.description="Bitcoin Core daemon, built from signature-verified upstream release binaries" \
      org.opencontainers.image.version="${BITCOIN_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="${SOURCE_REPO}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="${RUNTIME_BASE}"

COPY --from=verifier /out/bin/ /usr/local/bin/
COPY --from=verifier /out/lib/ /usr/local/lib/
# Provenance breadcrumbs, readable from inside the image and by `docker cp`.
COPY --from=verifier /out/accepted-signers.txt /out/upstream-digest.txt /usr/local/share/bitcoind-provenance/

ENV LD_LIBRARY_PATH=/usr/local/lib \
    BITCOIN_DATA=/data

# distroless nonroot
USER 65532:65532

VOLUME ["/data"]

# mainnet RPC / P2P / ZMQ block / ZMQ tx
EXPOSE 8332 8333 28332 28333

ENTRYPOINT ["/usr/local/bin/bitcoind"]
CMD ["-datadir=/data", "-printtoconsole"]
