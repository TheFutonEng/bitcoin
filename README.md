# bitcoind-container

A Bitcoin Core container image built from signature-verified upstream release
binaries, on a distroless base. The signed `SHA256SUMS` is committed, the build
itself never touches the network, and the published image carries a signed
manifest of everything inside it.

Scope is deliberately narrow: this repo **builds, verifies, and publishes an
image**. It says nothing about how you deploy or operate a node.

> **Status: published.** `ghcr.io/thefutoneng/bitcoin:31.1-1` is live. It is
> signed two ways — keyless and with a published key pair — and carries three
> attestations: provenance, SBOM, and a contents manifest accounting for every
> file in the image. All of it verifies from a clean machine using the commands
> in [Verifying what you pulled](#verifying-what-you-pulled), and the image
> inside it is reproducible: rebuild the tag yourself and you get the same bytes.
>
> ```
> ghcr.io/thefutoneng/bitcoin@sha256:0dc05d92fc66979482c0c1ed572c6d08f3f5b5c362e54f12fe885a432673649e
> ```
>
> Pin that digest.
>
> An earlier `ghcr.io/thefutoneng/bitcoin:31.1` also exists. It predates both
> the `<bitcoin version>-<image revision>` tagging scheme described under
> [Versioning](#versioning) and the reproducibility work, and is the only image
> published under a bare version tag. Prefer `31.1-1`.

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
   `keys/trusted-fingerprints.txt`. "Valid" excludes signatures from expired or
   revoked keys, and counts by primary fingerprint, so one signer with several
   subkeys counts once.
4. **Importable is not trusted.** Presence in `keys/` gets a key imported;
   presence in `trusted-fingerprints.txt` is what makes its signature count.
5. **Every base image is pinned by digest**, never by tag — both the runtime
   base and the throwaway verifier stage that checks the signatures.
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

## Versioning

Tags are `<bitcoin version>-<image revision>`:

```
ghcr.io/thefutoneng/bitcoin:31.1-1
                            ^^^^ ^
                            |    image revision
                            Bitcoin Core version
```

This is Debian's `upstream_version-debian_revision` model, for the same reason:
the payload is upstream's and the image around it is ours, and the two change on
unrelated schedules. A base image bump or a Dockerfile fix produces a genuinely
different artifact while shipping byte-identical Bitcoin Core binaries, and that
needs a name.

- **The revision starts at 1** for each Bitcoin version and increments when the
  published image changes for a reason that is not a new Bitcoin release.
- **It resets to 1** when the Bitcoin version changes.
- **Documentation and CI changes publish nothing**, so they do not bump it. A
  rebuild of an unchanged commit produces a bit-identical image, so there is
  never anything to publish for that either — see *Reproducible builds* below.

The same value is in the image as `org.opencontainers.image.version`, so an
image pulled by digest still says which revision it is. Tags live in the
registry and are not part of the artifact; the label is what survives a
`docker pull` by digest, which is what this README tells you to do anyway.

**Bare version tags are not published.** There is no `:31.1` being maintained —
it would be ambiguous the moment the image changes without the binaries
changing, which is exactly what the revision exists to express. Pin a digest for
anything real; use `31.1-1` when you want a name.

### The one exception, stated plainly

`ghcr.io/thefutoneng/bitcoin:31.1` exists. It was published on 2026-09-19,
before this scheme, and it is a legitimate signed image — the verification steps
below all work against it. It will not be updated and nothing else will be
published under a bare version tag.

The scheme deliberately starts at `31.1-1` rather than retroactively calling
that image `31.1-0`. Retagging it was the obvious move and was rejected: it was
built when the version label was just `31.1`, so it would have ended up tagged
`31.1-0` while labelled `31.1` — permanently, since the label is baked into a
signed digest. Every tag published under this scheme has a label that matches
it, and that is worth more than closing a one-image gap in the numbering.

## Using the image

```bash
docker run --rm ghcr.io/thefutoneng/bitcoin:31.1-1
```

That works with no arguments and no mount — it runs mainnet against an anonymous
volume. Everything below is about doing something more deliberate than that.

- Runs as UID/GID **65532:65532** (distroless `nonroot`).
- Datadir `/data`, declared as a `VOLUME` and present in the image owned by
  65532, so a fresh volume is usable without preparation.
- Entrypoint is `bitcoind` with `-datadir=/data -printtoconsole` already
  supplied. **Your arguments are appended, not substituted** — see below.
- Ports: `8332` RPC, `8333` P2P, `28332`/`28333` ZMQ. These are `EXPOSE`
  metadata only. RPC and ZMQ bind nothing unless you pass the matching
  `-rpcbind` / `-zmqpubrawblock` arguments; the ZMQ port numbers are
  convention, not a Bitcoin Core default.
- Ships `bitcoind` and `bitcoin-cli` only. No shell, no package manager, no
  entrypoint script, no in-container `chown`.
- Provenance breadcrumbs at `/usr/local/share/bitcoind-provenance/`, plus a
  cosign attestation.

### Arguments append

`-datadir=/data` and `-printtoconsole` live in `ENTRYPOINT`, which Docker
prepends to whatever you pass, so this keeps its datadir:

```bash
docker run -v bitcoin-data:/data ghcr.io/thefutoneng/bitcoin:31.1-1 -txindex=1
```

Both remain overridable, because Bitcoin Core takes the last duplicate on the
command line: `-datadir=/elsewhere` wins, and `-noprinttoconsole` silences the
logs.

This was not always true. Until `31.1-1` the flags were in `CMD`, which Docker
**replaces** rather than appends — so passing any argument silently moved the
datadir to `/home/nonroot/.bitcoin` on the container layer. The node started,
logged normally, ignored your volume, and lost the chain on `--rm`.
`make test` now asserts the mounted volume is non-empty afterwards.

### Configuration

There is no `bitcoin.conf` in the image, by design: a config file baked in is
one more thing to keep accurate and it cannot be overridden without shadowing
it. `bitcoind` runs on its own defaults until you provide one. Two ways:

```bash
# 1. inside the data volume — read automatically, no flag needed
docker run -v ./bitcoin.conf:/data/bitcoin.conf:ro -v bitcoin-data:/data \
  ghcr.io/thefutoneng/bitcoin:31.1-1

# 2. anywhere else, named explicitly
docker run -v ./conf:/etc/bitcoin:ro -v bitcoin-data:/data \
  ghcr.io/thefutoneng/bitcoin:31.1-1 -conf=/etc/bitcoin/bitcoin.conf
```

**[`examples/bitcoin.conf`](examples/bitcoin.conf) is a commented teaching
file**, not a recommended configuration — every value in it is a placeholder.
It documents the container-specific details, the most important being that
`datadir=` in a config file is **silently ignored**; Bitcoin Core accepts it on
the command line only.

That example is also a test fixture. `make test` mounts it, boots a node on it,
and checks every option it names still exists in the shipped `bitcoind` —
because Core does **not** fail on an option it does not recognise. It logs
`Ignoring unknown configuration value` and carries on, so a stale example would
leave someone's settings quietly doing nothing.

### Bind mounts still need preparing

A host directory keeps its own ownership, so the image's `/data` does not help
there:

```bash
mkdir -p /srv/bitcoin-data && chown 65532:65532 /srv/bitcoin-data
docker run --rm -v /srv/bitcoin-data:/data ghcr.io/thefutoneng/bitcoin:31.1-1
```

Under Kubernetes, `securityContext.fsGroup: 65532` does the same job for a
PersistentVolume.

### There is no shell

`docker exec ... sh` will not work. Run `bitcoin-cli` as its own entrypoint, and
give it the datadir — `--entrypoint` discards the image's own arguments:

```bash
docker run --rm --entrypoint /usr/local/bin/bitcoin-cli \
  -v bitcoin-data:/data ghcr.io/thefutoneng/bitcoin:31.1-1 \
  -datadir=/data getblockchaininfo
```

## Verifying what you pulled

The published image carries a cosign signature and three attestations:
provenance, an SPDX SBOM, and a **contents manifest** accounting for every file
in the image. Verifying is the point of all of it — none of the guarantees in
this README mean anything to you unless you check them yourself.

Signatures are made two ways. Keyless binds the signature to the release
workflow that built the image, so you are trusting a specific repo, ref and
workflow rather than whoever holds a key:

```bash
cosign verify \
  --certificate-identity-regexp \
    '^https://github\.com/TheFutonEng/bitcoin/\.github/workflows/release\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/thefutoneng/bitcoin:31.1-1
```

The identity is not optional. Without it you would accept a signature from
anyone Sigstore will issue a certificate to, which is no check at all.

Note the regexp is anchored at the start but **not** at the end: it accepts any
tag produced by this workflow, in this repository. That is deliberate — every
release should verify with the same published command — but it does mean the
signature attests to "a release of this repo", not "this specific version".
Pin the digest if you care which one you have.

A key-pair signature is also published for offline verification, where Sigstore
is unreachable. It deliberately carries no transparency-log entry, so add
`--insecure-ignore-tlog`; that warning is about the absence of a log, not about
the signature:

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog \
  ghcr.io/thefutoneng/bitcoin:31.1-1
```

The interesting attestation is the contents manifest. It tells you what is in
the image and, more usefully, that nothing else is:

```bash
cosign verify-attestation \
  --certificate-identity-regexp \
    '^https://github\.com/TheFutonEng/bitcoin/\.github/workflows/release\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --type https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1 \
  ghcr.io/thefutoneng/bitcoin:31.1-1 \
  | jq -r .payload | base64 -d | jq '.predicate.counts, .predicate.complete'
```

`"unaccounted": 0` and `complete: true` mean every file in the image was
matched to either the digest-pinned base or the signature-verified release
tarball — **with two documented exceptions, so read "every file" precisely.**

Five paths Docker injects into a container at runtime are excluded outright
(`DOCKER_RUNTIME_PATHS` in `scripts/verify-contents.sh`); they are not in the
image, and Docker overrides them at runtime, so content planted there is inert.
Two provenance breadcrumbs under `/usr/local/share/bitcoind-provenance/` are
matched by path rather than by hash, because their content is build-specific —
they could be replaced without failing verification. Everything else, including
both shipped binaries, is checked by content.

Swap `--type` for `spdxjson` or the `bitcoind-provenance/v1` type to check the
other two. `make verify-sig` runs all four checks at once if you would rather
not type them — for `31.1-1`, add `ATTESTATIONS_ON=index` (below).

### From `31.1-3`: one index, attestations per platform

From `31.1-3` the image is a multi-arch index, linux/amd64 and linux/arm64.

**`31.1-2` is public and unsigned — do not use it.** Its release pushed the
image and then failed before signing, on a tooling bug rather than a bad
artifact. The tag is not moved or reused; `31.1-3` is the same binaries,
signed and attested. Verifying `31.1-2` fails, as it should.

`docker pull` picks your platform, and `cosign verify` on the tag checks the
index signature exactly as above — every image inside it is signed too.

The **attestations move**. Each platform's contents manifest, SBOM and
provenance describe different bytes, so each is attached to *that platform's*
image digest rather than to the index. `cosign verify-attestation` has no
platform option, so name the digest:

```bash
ref=ghcr.io/thefutoneng/bitcoin:31.1-3
digest=$(docker buildx imagetools inspect "$ref" --format \
  '{{range .Manifest.Manifests}}{{if eq .Platform.Architecture "arm64"}}{{.Digest}}{{end}}{{end}}')

cosign verify-attestation \
  --certificate-identity-regexp \
    '^https://github\.com/TheFutonEng/bitcoin/\.github/workflows/release\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --type https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1 \
  "ghcr.io/thefutoneng/bitcoin@${digest}" \
  | jq -r .payload | base64 -d | jq '.predicate.image, .predicate.triple, .predicate.complete'
```

**Check `.predicate.image`, not just the signature.** It must end in the digest
you asked about. A valid signature proves who made a statement, not what the
statement is about: the arm64 contents manifest attached to the amd64 image
verifies perfectly well with cosign. `make verify-sig` checks this for every
platform — the contents manifest names the digest, the SBOM describes it, and the
provenance is for the same tarball — and fails if any attestation on an image
describes a different one. That case was tested by attaching exactly that, with
the real key.

`make verify-sig` defaults to this layout. Releases up to `31.1-1` attached
their attestations to the index instead, so check those with
`make verify-sig TAG=31.1-1 ATTESTATIONS_ON=index`. The layout is chosen
explicitly rather than detected: a verifier that fell back to the old layout
when per-platform attestations were missing would accept an image stripped of
them.

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
scripts/verify-reproducible.sh   prove this commit builds the same image bytes anywhere
scripts/list-platforms.sh        the platform images inside a published index, from the registry
scripts/compare-contents.sh      prove two images hold exactly the same files
scripts/sign-image.sh            sign the index and its images; attest each platform
scripts/verify-signatures.sh     prove signatures and attestations, and what each is about
tests/test-threshold.sh          negative tests for the signature threshold
tests/test-config.sh             prove config and the datadir reach the container
examples/bitcoin.conf            commented teaching file, and the fixture the test runs
.github/workflows/ci.yml         runs the whole chain on every pull request, per platform
.github/workflows/release.yml    tag-triggered: boot each platform natively, then publish
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

## Reproducible builds

Build the tagged commit yourself and check you get the same image:

```bash
git checkout <the release tag>          # e.g. v31.2
make fetch-tarball
make verify-repro-published TAG=31.2
```

That checks linux/amd64. For a multi-arch release, add `PLATFORM=linux/arm64`
to both `make` commands to check the other image — it cross-builds, so an amd64
machine can check the arm64 image and needs no emulation to do it.

Each release prints the expected image manifest digests, one per platform, in
its workflow summary, so you can also compare by eye with `make repro-digest`.

That rebuilds from the commit and compares against what is actually in the
registry. It is a stronger statement than a signature: a signature says who
built the image, this says anyone would have built the same one.

**Read what is being compared.** The published digest you pin is an OCI *index*,
which wraps the image manifest together with the attestations. The **image
manifest** is reproducible; the index is not and never will be, because buildkit
writes `startedOn`, `finishedOn` and a random `invocationId` into the SLSA
provenance, and syft writes a timestamp and a random UUID into the SBOM. Two
builds of the same commit differ there every time. The check above compares the
image manifest inside the index, which is the part that describes the bytes you
actually run.

**Confirmed for `31.1-1`**, the first release built with layer-timestamp
rewriting. A laptop rebuilding the tag produces
`sha256:bbd7da4f…ae2c1`, which is exactly the image manifest inside the
published index — two machines, same bytes.

**`31.1` predates this and cannot match.** It was built without timestamp
rewriting, so its files carry the wall-clock time of that build. The check says
so rather than passing quietly.

On every pull request CI also asserts that GitHub runners build the same images
as the digests committed in `reproducible-digest.txt` — one per platform,
linux/amd64 and linux/arm64, each checked on a native runner of that
architecture. The file is generated on a different machine, an amd64 box that
cross-builds arm64, so the arm64 check is two different CPU architectures
agreeing on the bytes. Verified by hand across two buildkit versions (v0.29.0
and v0.32.2), two drivers, and via both an OCI export and a registry push.

One thing the check has to do, and it is not obvious: **it builds with
`--no-cache`.** BuildKit's cache key does not include `SOURCE_DATE_EPOCH`, so a
layer cached from a build at a different epoch is reused with its original
timestamps and never re-rewritten. Without the flag, a machine that had built
this repo before would report a mismatch on a perfectly good image — which is
what happened on the v31.1-1 release, and is why the flag is there.

## Known gaps

- **Negative tests cover the signature threshold only.** `make test` runs 35
  assertions proving both threshold implementations agree and fail closed, on
  every pull request. The other gates — a planted file in the image, a tampered
  keyring, injected pin drift, an unwritable datadir, an unreadable image, a
  swapped image at the same tag — have each been shown to fail closed by hand,
  but those proofs are ad hoc rather than runnable, so nothing re-checks them.
- **arm64 is built and tested but not yet published.** CI runs the whole chain
  on a native arm64 runner — smoke, config tests, binary and contents
  verification, and the reproducible digest — but every published tag so far is
  amd64 only. The first multi-arch release will be `31.1-3`.
- **The published *index* digest is not reproducible, and cannot be.** The image
  inside it is. See "Reproducible builds" above; the distinction is real and the
  index digest is the one you pin.
- **Two deliberate holes in the contents manifest.** Five paths Docker injects
  into a container (`DOCKER_RUNTIME_PATHS`) are excluded outright; content
  planted there is inert because Docker overrides all five at runtime, but it is
  not checked. And two provenance breadcrumbs are matched by path rather than by
  hash, because their content is build-specific — they could be replaced without
  failing verification.
- **The two verification implementations are not independent.** The `Dockerfile`
  and `scripts/verify.sh` carry the same hand-written parser, so they share
  their bugs, and have done twice. `make cross-check`, which runs Bitcoin Core's
  own `verify.py` against the same artifacts, is the only real second opinion.
  `make test` now at least proves the two copies behave identically on inputs
  designed to separate them, which is a narrower claim than independence.

## License

Bitcoin Core is distributed under the MIT license. This repository packages
upstream release binaries; it does not modify them.
