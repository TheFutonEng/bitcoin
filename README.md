# bitcoind-container

A Bitcoin Core container image built from signature-verified upstream release
binaries, on a distroless base. The signed `SHA256SUMS` is committed, the build
itself never touches the network, and the published image carries a signed
manifest of everything inside it.

Scope is deliberately narrow: this repo **builds, verifies, and publishes an
image**. It says nothing about how you deploy or operate a node.

> **Status: the build and verification chain work end to end.** The allowlist
> holds 10 Bitcoin Core builders; `make verify` accepts 10 signatures against a
> threshold of 6 on the real 31.1 release, independently confirmed by Core's own
> `verify.py`. `make build` runs with no network, `make smoke` boots a regtest
> node, and `make verify-contents` accounts for every file in the image. CI runs
> the whole chain on every pull request. Publishing and signing are not done yet
> — see [Known gaps](#known-gaps).

## Why this exists

The widely used [`bitcoin/bitcoin`](https://hub.docker.com/r/bitcoin/bitcoin)
images on Docker Hub are, by their own description, unofficial — the Docker Hub
page states they are "not endorsed or associated with the Bitcoin Core project
on Github". They are carefully built and their pipeline is public and auditable.
This repo exists because a node image in this environment has to be one we own,
build, and can attest to ourselves — not because there is anything wrong with
theirs.

Be precise about what that ownership buys, though, because the obvious answer is
wrong. **It is not better provenance.** Upstream publishes Guix-reproducible
release binaries signed by a threshold of independent builders, and any image
built from those binaries contains the same bytes. That is measured here, not
assumed: `make verify-upstream` extracts the binaries from `bitcoin/bitcoin` and
reports the same hashes `make verify-image` reports for ours.

What ownership does give you:

1. **Base image control.** This image is distroless — no shell, no package
   manager, a far smaller CVE surface, and scanner evidence you own. It runs as
   `USER 65532:65532`, set at build time, with no entrypoint script.
2. **Artifact ownership.** You publish and retain the image yourself. Upstream
   does withdraw releases — 30.0 and 30.1 are already gone from bitcoincore.org
   — so the image you published is the archive.
3. **Lifecycle ownership.** Version cadence, signing under your own key, SBOM,
   and no dependency on a third party's release timing or registry. You would
   have to re-sign and re-scan any image you did not build anyway.
4. **A signed inventory of the contents.** `make verify-contents` accounts for
   every file in the image against the digest-pinned base and the verified
   release tarball, and publishes the result as a manifest. That is the one
   guarantee here that is genuinely hard to get any other way.

What it costs you: you now own Core release tracking, base-image CVE response,
and multi-arch. You also take on trust in `debian:bookworm-slim` for the
throwaway verifier stage, and in the distroless base. The total supply-chain
surface is not obviously smaller than consuming a prebuilt image.

Framed honestly, this is a **hardening and ownership** exercise. The provenance
was already fine.

## Design invariants

1. **No build step touches the network.** `make build` passes `--network=none`
   and reads only from `upstream/`, staged beforehand by `make fetch`.
2. **The signed metadata is committed; the tarball is not.** `SHA256SUMS` and
   `SHA256SUMS.asc` (~11 KB) are the trust anchor and live in git. The tarball is
   gitignored — it is self-authenticating against those signed sums, so
   committing ~86 MB per release per architecture would add no integrity.
3. **Threshold signature verification.** `SHA256SUMS` must carry at least
   `MIN_GOOD_SIGS` (default 6) valid signatures from keys on the allowlist in
   `keys/trusted-fingerprints.txt`.
4. **Importable is not trusted.** Presence in `keys/` gets a key imported;
   presence in `trusted-fingerprints.txt` is what makes its signature count.
5. **The runtime base image is pinned by digest**, never by tag.
6. **Verification logic is intentionally duplicated** in the `Dockerfile` and
   `scripts/verify.sh`, so that a standalone check — on an air-gapped host, as a
   pre-commit gate, or in future CI — and the image build enforce the same
   rule.

## Bootstrapping

The allowlist ships empty on purpose, so the human review step cannot be
skipped silently.

```bash
# Import Bitcoin Core builder keys from guix.sigs
scripts/import-builder-keys.sh

# Review every fingerprint. Corroborate each from a second source before
# keeping it — a key you cannot vouch for is a question, not a formality.
$EDITOR keys/trusted-fingerprints.txt.candidate
mv keys/trusted-fingerprints.txt{.candidate,}

# Delete the .asc files for keys you did not keep. keys/ holds only the
# allowlisted builders; `make check-pins` enforces that none are missing.
make check-pins
```

## Usage

```bash
# Per version, on a connected machine
make fetch VERSION=31.1          # downloads + verifies; tarball stays gitignored
git add upstream/SHA256SUMS upstream/SHA256SUMS.asc
git commit -m "upstream: bitcoin core 31.1 sums"

# Build and prove the result
make build smoke verify-image

# Publish — attestations ride on the push, not on a local --load build
make push
make sbom sign attest COSIGN_KEY=...
make digest          # publish this digest; consumers pin it
```

`make verify-image` is the regression test on the build: it pulls the binaries
back out of the image and proves they are byte-identical to the tarball that
cleared the signature threshold.

Because that check works against *any* image, you can point it at
`bitcoin/bitcoin` too:

```bash
make verify-upstream   # same check, run against bitcoin/bitcoin
```

That target overrides `BIN_PATH` to `/opt/bitcoin-<version>/bin`, because
`bitcoin/bitcoin` unpacks the release tarball into `/opt` and puts it on `PATH`
rather than installing into `/usr/local/bin`.

Run `make help` for the full target list.

## Using the image

- Runs as UID/GID **65532:65532** (distroless `nonroot`).
- Datadir `/data`, declared as a `VOLUME`, with `BITCOIN_DATA=/data`.
- Entrypoint is `bitcoind` directly — no shell, no entrypoint script, no
  in-container `chown`. Configuration arrives as arguments or a mounted
  `bitcoin.conf`.
- Ports: `8332` RPC, `8333` P2P, `28332`/`28333` ZMQ. These are `EXPOSE`
  metadata only. RPC and ZMQ bind nothing unless you pass the matching
  `-rpcbind` / `-zmqpubrawblock` arguments; the ZMQ port numbers are
  convention, not a Bitcoin Core default.
- Ships `bitcoind` and `bitcoin-cli` only.
- Provenance breadcrumbs at `/usr/local/share/bitcoind-provenance/`, plus a
  cosign attestation.

**The datadir must be writable by UID 65532 before you start the container.**
The image deliberately contains no entrypoint script and does no in-container
`chown`, and `/data` does not exist in the distroless base — so a fresh named
volume comes up owned by root and `bitcoind` cannot write to it. Prepare the
directory on the host:

```bash
mkdir -p /srv/bitcoin-data && chown 65532:65532 /srv/bitcoin-data

docker run --rm -v /srv/bitcoin-data:/data \
  registry.example.com/bitcoin/bitcoind:31.1 \
  -datadir=/data -printtoconsole
```

Because there is no shell in the image, `docker exec ... sh` will not work. Use
`bitcoin-cli` as the entrypoint instead:

```bash
docker run --rm --entrypoint /usr/local/bin/bitcoin-cli \
  registry.example.com/bitcoin/bitcoind:31.1 -version
```

## Repository layout

```
Dockerfile                       two stages: verifier (throwaway) -> runtime (distroless)
Makefile                         fetch / verify / build / smoke / verify-image / sign / attest
scripts/fetch-release.sh         connected-machine: stage a release into upstream/
scripts/verify.sh                threshold signature check + digest check + provenance.json
scripts/verify-image.sh          extract binaries from any image, compare to verified tarball
scripts/verify-contents.sh       prove every file in the image is accounted for
scripts/cross-check-verify-py.sh second opinion from Core's own verify.py
scripts/import-builder-keys.sh   one-time bootstrap of keys/ from guix.sigs
scripts/fetch-sums-from-guix-sigs.sh  recover signed sums for a withdrawn release
scripts/check-pins.sh            assert duplicated values agree across files
scripts/build-keyring.sh         regenerate the keyring the container build uses
.github/workflows/ci.yml         runs the whole chain on every pull request
keys/                            pubkeys for the allowlisted builders, the allowlist,
                                 and the derived keyring the build verifies against
upstream/                        committed: SHA256SUMS + .asc. Gitignored: the tarball.
```

## When upstream withdraws a release

bitcoincore.org does remove old releases — 30.0 and 30.1 are already gone. The
signed sums survive in `guix.sigs`, so `make fetch` falls back to reconstructing
them from there automatically, and you still learn the correct hash. The
*binaries* have no fallback: GitHub releases carry no assets, so the bytes must
come from your own published image or archive, checked against the recovered
sums.

## Known gaps

- **Publishing and signing are unproven.** `sign`, `attest` and `verify-sig`
  have never run — they need a registry, a pushed image and a key. `verify-sig`
  also verifies only one of the three predicates `attest` attaches, so the
  contents manifest currently has no verification path.
- **`REGISTRY` is still the placeholder** `registry.example.com/bitcoin`.
- **No formal negative-test suite.** Individual gates have been proven to fail
  closed — a planted file, a tampered keyring, injected pin drift, an unwritable
  datadir — but those proofs are ad hoc rather than a runnable suite.
- **arm64 is untested.** The pinned base is already a multi-arch index, so the
  base is not the blocker.
- **`DOCKER_RUNTIME_PATHS` is a deliberate hole.** Five paths Docker injects
  into a container are excluded from the contents manifest. Content planted
  there is inert because Docker overrides all five at runtime, but they are not
  checked.

## License

Bitcoin Core is distributed under the MIT license. This repository packages
upstream release binaries; it does not modify them.
