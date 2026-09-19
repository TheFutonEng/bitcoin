# bitcoind-container

Builds a Bitcoin Core container image from signature-verified upstream release
binaries, on a distroless base we control. The signed `SHA256SUMS` is committed;
the tarball is not. No build step touches the network, and the published image
carries a signed manifest of everything inside it.

Scope: builds, verifies, and publishes an image. Nothing about deployment.

## What this actually buys you — read this before defending the repo to anyone

Be precise about the justification, because the obvious one is wrong.

`bitcoin/bitcoin` on Docker Hub (built from `willcl-ark/bitcoin-core-docker` by a
Core contributor, and **explicitly unofficial** — the Docker Hub page says "not
endorsed or associated with the Bitcoin Core project") already verifies upstream
signatures in CI using Core's own `verify.py`, which enforces a **minimum
threshold of good signatures** rather than accepting a single maintainer
signature. Their Dockerfiles and workflows are public.

Verified against `willcl-ark/bitcoin-core-docker` `31.1/Dockerfile` (2026-09-12):
they clone guix.sigs, `gpg --import builder-keys/*`, and run
`./verify.py --min-good-sigs 6 pub ...`. **We now match this at 6** (raised
from 3 on 2026-09-12). Their runtime is `debian:bookworm-slim`, the
tarball is unpacked to `/opt/bitcoin-<version>/`, there is no `USER` directive
(it drops privileges with `gosu` at entrypoint), and the datadir is
`/home/bitcoin/.bitcoin`. Their `alpine` and `master` tags are built from source
in CI, so the identical-bytes claim covers only the Debian-based tags.

So this repo is **not** more cryptographically rigorous than theirs, and for
the Debian-based tags the binaries in both images are the same upstream bytes.
**Measured 2026-09-14**, not assumed: `make verify-upstream` extracts from
`bitcoin/bitcoin:31.1` and gets `bitcoind 986e63b3…88a08` and
`bitcoin-cli 4e3a0fde…86034` — byte-identical to what `make verify-image`
reports for our own image. Anyone who tells you otherwise — including earlier
versions of this file — is overselling it.

What this repo actually gives you:

1. **Base image control.** Theirs is Debian with a shell and a package manager
   in it. This one is distroless: no shell, no package manager, a far smaller
   CVE surface, and scanner evidence you own. This is not substitutable at any
   price, and it is the strongest single reason the repo exists.
2. **Artifact ownership.** You publish and retain the image yourself, so the
   version you shipped stays available on your terms rather than a third
   party's. See "Why the tarball is not committed" below — the published image,
   not git, is the archive.
3. **Lifecycle ownership.** Version cadence, signing under your key, SBOM, and
   no dependency on one volunteer's Docker Hub account continuing to exist.
   You would have to re-sign and re-scan a third-party image anyway.
4. **A narrow trust gap closed.** Their workflow is auditable but you cannot
   confirm the image on Docker Hub came from it — compromised registry
   credentials would not show up in the repo. See the caveat below, though.

What it does **not** give you, and what you are paying:

- No better binaries. Same bytes.
- You now own Core release tracking, base-image CVE response, and arm64.
- You added trust dependencies that did not exist before: `debian:bookworm-slim`
  in the verifier stage and the distroless base. Total supply chain surface is
  not obviously smaller than just consuming theirs.
- Point 4 above is cheap to close without this repo: `make verify-upstream` runs
  the same extract-and-hash check against `bitcoin/bitcoin` and proves its
  binaries are the correct upstream bytes. If provenance were the only concern,
  that check plus their image would be the right answer.
  (This target had `BIN_PATH` wrong until 2026-09-12 — it assumed
  `/usr/local/bin`, but their binaries live in `/opt/bitcoin-<version>/bin`, so
  it had never actually run. Fixed and run 2026-09-14; both binaries MATCH.)

Framed honestly: this is a **hardening and ownership** exercise. The provenance
was already fine.

## Why the tarball is not committed

Decided 2026-09-12. Earlier versions of this file justified vendoring the
release tarball into git as "offline rebuildability". That was overstated.

**Committing the tarball adds no integrity.** `SHA256SUMS` carries signatures
from a threshold of builders and is committed at ~11 KB. Any tarball fetched
later is self-authenticating against it. The 86 MB blob proves nothing the
11 KB does not — while costing ~172 MB per release across two arches,
permanently, in every clone, un-prunable without rewriting history. `.tar.gz`
is already compressed, so git cannot delta it.

**The availability risk is real, though.** Measured 2026-09-12: Bitcoin Core
30.0 and 30.1 are **gone** from `bitcoincore.org` — the directories are absent
from the index, not merely the sums files. 22.0 through 29.0, 30.2, 30.3 and
31.1 are still served. Upstream does withdraw releases, so "rebuild the image I
shipped last year" can genuinely become impossible.

**What GitHub does and does not preserve** (measured 2026-09-12). The
`bitcoin/bitcoin` GitHub *releases* carry **no binaries at all** — v29.4, v31.1,
v30.3, v31.0, v28.4, v29.3, v30.2 and v30.1 all report `assets=0`. They are
release notes against a tag. The *tags* do survive, `v30.0` and `v30.1`
included, but that is source: turning it back into official binaries means
running the Guix build yourself.

What GitHub does preserve is the **trust anchor**. `guix.sigs` retains the
attestations for withdrawn releases — 30.0 has 24 signer directories, 30.1 has
18 — and those sums are authoritative: for 31.1, all 16 signers'
`all.SHA256SUMS` are byte-identical to what bitcoincore.org serves.
`scripts/fetch-sums-from-guix-sigs.sh` exploits this, and `fetch-release.sh`
falls back to it automatically. Verified against 30.0, which is genuinely gone
upstream: it recovers the sums with 23 of 23 signers agreeing, 23 valid
signatures against our allowlist, and the correct tarball hash
`00964ae3…54248`. Note it yields *more* signatures than the upstream bundle
(16 vs 11 for 31.1), because bitcoincore.org bundles a subset.

**So verifying and obtaining are separable, and only obtaining is at risk.**
Even for a withdrawn release you can still learn the correct hash; what you
cannot do is get a file matching it.

**That is answered by publishing, not by git.** The plan is to publish the built
containers as releases on this repo, so the artifact itself persists. The
published image is the archive: it contains the exact verified binaries, and the
signed contents manifest travels with it.

**The gap this leaves.** Publishing solves "I need the old image". It does not
solve "I need that Bitcoin version on a *new* base" — the response to a
distroless CVE, which is the load-bearing reason this repo exists. That rebuild
needs the binaries again, and upstream may have withdrawn them. Tracked as a
follow-up: add a build path that sources binaries from a previously published
image rather than a tarball, using the same hash comparison `verify-image.sh`
already performs.

## Invariants

1. **No build step touches the network.** `make build` passes `--network=none`
   and reads only from `upstream/`, which `make fetch` stages beforehand. If a
   change requires network *during the build*, the change is wrong. Note this is
   input-hermeticity, not an airgap: resolving the base images still needs a
   registry unless they are already cached locally.
2. **The signed metadata is committed; the tarball is not.** `SHA256SUMS` and
   `SHA256SUMS.asc` (~11 KB) live in git and are the trust anchor. The release
   tarball is gitignored and fetched on demand — it is self-authenticating
   against the committed signed sums, so committing ~86 MB per release per arch
   would add no integrity, only permanent history.
3. **Threshold signature verification.** `SHA256SUMS` must carry at least
   `MIN_GOOD_SIGS` (**default 6**) valid signatures from keys on the allowlist
   in `keys/trusted-fingerprints.txt`. This is the same *mechanism* upstream
   tooling uses, at the same threshold `bitcoin/bitcoin` uses; it is table
   stakes, not a differentiator. The default lives in three places — Makefile,
   Dockerfile `ARG`, and `scripts/verify.sh` — change all three together. Do not
   reduce it to 1.
4. **Importable is not trusted, and the two sets are kept equal anyway.**
   Presence in `keys/` gets a key imported; presence in
   `trusted-fingerprints.txt` is what makes its signature count. The check stays
   because it is what stops a stray key file from mattering — but we do not rely
   on it as a filter. `keys/` holds **only** the allowlisted keys, because a
   non-allowlisted key cannot change the outcome and is just another blob gpg
   parses at verification time. Adding a signer is one reviewed commit carrying
   both the `.asc` and the fingerprint; `check-pins.sh` fails if an allowlisted
   fingerprint has no key file, since that failure is otherwise silent.
5. **The runtime base image is pinned by digest**, never by tag.
6. **Verification logic lives in two places** (`Dockerfile` and
   `scripts/verify.sh`) deliberately, so a standalone check and the image build
   agree. Change one, change the other. Task below to add a test that they
   match. Both are run by CI on every pull request.

## Layout

```
Dockerfile                       two stages: verifier (throwaway) -> runtime (distroless)
Makefile                         fetch / verify / build / smoke / verify-image / sign / attest
scripts/fetch-release.sh         connected-machine: stage release into upstream/
scripts/verify.sh                threshold sig check + digest check + provenance.json
scripts/verify-image.sh          extract binaries from any image, compare to verified tarball
scripts/verify-contents.sh       prove EVERY file in the image is accounted for
scripts/check-pins.sh            assert duplicated values agree across files
scripts/build-keyring.sh         regenerate keys/trusted-keyring.gpg from keys/*.asc
scripts/sign-image.sh            sign + attach all three attestations (key and/or keyless)
scripts/verify-signatures.sh     prove the signature AND all three attestations round-trip
.github/workflows/ci.yml         the whole chain on every PR; no secrets, actions SHA-pinned
.github/workflows/release.yml    tag-triggered publish to GHCR; the ONLY workflow with secrets
scripts/import-builder-keys.sh   one-time bootstrap of keys/ from guix.sigs
scripts/fetch-sums-from-guix-sigs.sh  recover signed sums when upstream withdraws a release (read its header)
scripts/cross-check-verify-py.sh second opinion on the threshold from Core's own verify.py
keys/                            armored pubkeys for the allowlisted builders ONLY,
                                 trusted-fingerprints.txt, and trusted-keyring.gpg
                                 (derived; what the container build verifies against)
upstream/                        committed: SHA256SUMS + .asc. Gitignored: the tarball.
                                 Named for where the bytes come from, not how they
                                 are stored — only the sums are actually vendored.
```

## Workflow

```bash
# one time, on a connected box, with human review of the output
scripts/import-builder-keys.sh
$EDITOR keys/trusted-fingerprints.txt.candidate   # prune to what you can corroborate
mv keys/trusted-fingerprints.txt{.candidate,}
# then delete the .asc files you did not keep — keys/ tracks the allowlist
make check-pins

# per version
make fetch VERSION=31.1          # downloads, verifies, cross-checks against verify.py
git add upstream/SHA256SUMS upstream/SHA256SUMS.asc
git commit -m "upstream: bitcoin core 31.1 sums"  # the tarball is gitignored
make build smoke verify-image verify-contents
make push                        # rebuilds with mode=max provenance + SBOM
make sbom sign attest COSIGN_KEY=...
make digest          # publish this; consumers pin it
```

`make verify-image` is the regression test on the build: it pulls the binaries
back out of the image you just produced and proves they are byte-identical to
the tarball that cleared the signature threshold. If the Dockerfile ever starts
doing something clever, this catches it.

## What consumers need to know

- The published image is **`ghcr.io/thefutoneng/bitcoin`** — named `bitcoin`,
  not `bitcoind`, to match what every other Bitcoin Core container is called.
  The binary inside is still `bitcoind`, and the attestation predicate types
  stay `bitcoind-*` because they describe the daemon payload rather than the
  image. That asymmetry is deliberate; do not "fix" it. Changing a predicate
  type after anything is published breaks verification for every image already
  signed with the old one.
- Runs as UID/GID **65532:65532** (distroless `nonroot`). Changes if the runtime
  base changes.
- Datadir `/data`, declared `VOLUME`, `BITCOIN_DATA=/data`.
- Entrypoint is `bitcoind` directly. No shell, no entrypoint script, no
  in-container chown. Config arrives as args or a mounted `bitcoin.conf`.
- Ports: 8332 RPC, 8333 P2P, 28332/28333 ZMQ.
- Ships `bitcoind` and `bitcoin-cli` only.
- Provenance breadcrumbs at `/usr/local/share/bitcoind-provenance/`, plus a
  cosign attestation.

## Open work

### Done since the initial commit

- [x] **Cross-check against Core's `verify.py`** — `scripts/cross-check-verify-py.sh`,
      wired into `fetch-release.sh` (skippable with `SKIP_CROSS_CHECK=1`) and
      exposed as `make cross-check`. Downloads verify.py at a pinned commit
      (`facaf5621446…`, sha256 `f35fbf10…`; bumping either is a reviewed
      commit), builds a keyring from **only** the allowlisted fingerprints so
      both tools see the same candidate set, runs `verify.py bin`, and compares
      against what `scripts/verify.sh` actually reports. Verified 2026-09-12
      against real 31.1 artifacts: both say 11, verdict pass. Reverting
      verify.sh to the pre-fix `$3` parser makes it report 11 vs 7 and exit 1,
      so it demonstrably catches the bug that motivated it.

      Two traps found while building it, both worth remembering.
      `--min-good-sigs` is a **global** option on verify.py and must precede the
      `bin` subcommand or argparse rejects it. And the first draft recomputed our
      signer set inline and forgot to intersect it with the allowlist — it
      reported 11 either way and would have caught nothing. **A cross-check must
      invoke the real gate, not a third re-derivation of it.**

### Fixed 2026-09-14 — the build works

- [x] **The verifier stage no longer needs the network.** `apt-get install gnupg`
      is gone; the stage uses `gpgv`, which `debian:bookworm-slim` already ships.
      `gpgv` cannot import, so it verifies against `keys/trusted-keyring.gpg`,
      generated on the host by `scripts/build-keyring.sh` from the same
      `keys/*.asc` the host tooling uses. The allowlist intersection is
      unchanged and still applied afterwards, so a key in the keyring that is not
      allowlisted still does not count — invariant 4 survives the switch.
      `check-pins.sh` asserts every allowlisted fingerprint is in the keyring,
      tested against a deliberately 9-key keyring.

      The keyring build is deterministic (fixed fingerprint order), so
      `scripts/build-keyring.sh && git diff keys/trusted-keyring.gpg` is a real
      review. Verified `mawk` — Debian's default awk, not gawk — handles the
      `VALIDSIG` parse identically.

- [x] **Dead `lib/` handling removed.** 31.1 ships no `lib/`, so the
      `if [ -d /unpack/lib ]` branch, the `/out/lib/` copy and
      `LD_LIBRARY_PATH=/usr/local/lib` all advertised a dependency that does not
      exist. Gone.

- [x] **`ARG RUNTIME_BASE` re-declared in the runtime stage.** A latent bug that
      shipped in PR #2: a global `ARG` above the first `FROM` is visible to
      `FROM` instructions but **not inside a stage**, so
      `org.opencontainers.image.base.name` silently expanded to `""`. That broke
      `verify-contents.sh` entirely, since it resolves the base from that label.
      It went unnoticed because the earlier end-to-end test used a hand-built
      fixture with the label set manually — which validated the script but never
      validated that the Dockerfile produces the label. **A fixture that supplies
      the thing under test proves nothing about the thing that must supply it.**

- [x] **`make smoke` now asserts.** It previously backgrounded `docker run`,
      slept and killed the client PID, so it always exited 0. It now runs the
      node with a deadline and requires `init message: Done loading`. The first
      run that could fail, did: `/data` is not writable by 65532, because the
      declared `VOLUME` does not exist in the distroless base and comes up
      root-owned. That is the consumer caveat the README documents, now
      confirmed rather than inferred. The target mounts a tmpfs owned by 65532 —
      the `--tmpfs` there is load-bearing, not incidental.

**First full green run, 2026-09-14:**

```
make build           image built, --network=none, 10 accepted signers in-build
make smoke           bitcoind v31.1.0 + bitcoin-cli run; regtest boot: OK
make verify-image    MATCH bitcoind, MATCH bitcoin-cli
make verify-contents 1660 base + 2 verified + 2 generated = 1664, 0 UNACCOUNTED
```

### Do these next

With the build working and every gate green, the remaining priority items are
about publishing and proving. `verify-contents.sh` is the thing that makes this
repo's guarantees stronger than what is available elsewhere, and it now runs for
real — what is left is getting the result published and signed.

- [x] **`verify-sig` now verifies all three predicates.** Done 2026-09-15. It
      checked only provenance while `attest` attached three, so the contents
      manifest — the distinctive guarantee — had no verification path.
      `scripts/verify-signatures.sh` checks the signature plus provenance, SBOM
      and contents, in whichever signing modes are configured.

      **Both signing modes, deliberately.** Keyless binds the signature to the
      release workflow on a tag, which is a stronger provenance claim than a key
      file and is logged to Rekor. The key pair is verifiable offline with no
      dependency on Sigstore, which is what survives an air gap. Key-pair
      signatures intentionally skip Rekor, so verifying them passes
      `--insecure-ignore-tlog`; that warning is about the absence of a
      transparency log, not about the signature.

      **Proven end to end 2026-09-15** against a throwaway `registry:2` and a
      throwaway key: push, sbom, sign, attest x3, verify all four — green. Fails
      closed both ways: verifying with the wrong public key exits non-zero, and
      pushing a tampered image to the same tag also fails, because the signature
      is bound to the digest rather than the tag.

      **Keyless cannot be exercised locally** — it needs an OIDC token that only
      CI has, and signing keylessly from a laptop would write test entries to the
      public transparency log. The first real tag is its first test.

      cosign v3 notes, both found by running it: `--tlog-upload=false` errors
      unless `--use-signing-config=false` is also passed, and predicate types are
      given with `--type`. Verified against v3.1.3.
- [x] **First real publish — v31.1, 2026-09-19.**

      ```
      ghcr.io/thefutoneng/bitcoin@sha256:35c21e6979a219ac7c292ea7442c8ee3dd4eaa9627fe4b9b8dc7b3e2fea9392e
      ```

      That digest is the OCI **index** — image manifest plus attestation
      manifest — which is what consumers pin. The tag was signed
      (`git tag -s v31.1`) and verifies against the SSH signing key.

      **Verified from a clean machine, not from the runner**, using the exact
      commands published in the README: signature OK, and all three attestations
      OK — provenance, SBOM, contents manifest. The contents manifest reads back
      `total 1664, unaccounted 0, complete true`. That is the whole point of the
      repo arriving intact at the other end: a consumer can verify, themselves,
      that nothing else is in the image.

      A workflow verifying its own signature proves the plumbing. An outsider
      verifying it with the published regexp proves the claim. Do the second one
      after every release.

      **The GHCR-goes-private worry did not apply** — the package inherited
      public visibility from the public repo. Anonymous pull token, HTTP 200, no
      manual step needed.

- [ ] **Add a rebuild-from-published-image path.** Publishing preserves the old
      image but not the ability to put that Bitcoin version on a *new* base,
      which is exactly what a distroless CVE demands. Source the binaries from a
      previously published image instead of a tarball, comparing hashes the way
      `verify-image.sh` already does, so a base bump does not depend on upstream
      still hosting the release.
- [x] **`make verify-upstream` run, 2026-09-14.** It had never executed —
      `BIN_PATH` was wrong until 2026-09-12, then it was blocked on the
      bootstrap. Both binaries MATCH:
      `bitcoind 986e63b3…88a08`, `bitcoin-cli 4e3a0fde…86034`.

      **Those are the same hashes `make verify-image` reports for our own
      image.** So "the binaries in both images are identical bytes" — the claim
      the entire justification section rests on — is now *measured*, not
      inherited from documentation. If that ever stops being true, this target
      is what says so.
- [x] **Contents-completeness attestation — `scripts/verify-contents.sh`.**
      *This is the answer to "can we do attestation better than
      bitcoin/bitcoin", and the answer is yes.* `verify-image.sh` proves two
      named binaries are the right bytes; it proves nothing about what *else* is
      in the image, which is exactly the gap their docs warn about. This script
      closes it by subtraction: export the image rootfs, hash every regular file
      and record every symlink target, then classify each against (a) the base
      image named by the image's own
      `org.opencontainers.image.base.name` label and (b) files from the verified
      tarball. Anything left over is UNACCOUNTED; a base path whose content
      differs is MODIFIED. Both fail the run. Emits `contents-manifest.json`,
      attached by `make attest` under its own predicate type so a consumer can
      re-derive "these N files, these hashes, nothing else" offline.

      **Tested, fails closed** — three fixtures built on the distroless base:
      unmodified (all accounted, exit 0), one extra file (UNACCOUNTED, exit 1),
      one modified `/etc/passwd` (MODIFIED, exit 1). Re-confirmed 2026-09-14
      against the real image by planting a file: UNACCOUNTED, exit 1.

      Measured base composition: 1788 tar entries = 1288 regular files + 377
      symlinks + 123 directories. Directories carry no content and are ignored,
      leaving 1665 content-bearing entries, of which 5 are Docker runtime
      injections excluded by `DOCKER_RUNTIME_PATHS` — so the script covers
      **1660** base entries.

      **Proven end to end 2026-09-14** against the real image: 1660 base files
      + 2 verified binaries + 2 generated breadcrumbs = 1664 entries, zero
      unaccounted. The tarball branch now executes for real.

      **Two known holes, both by path rather than hash.** Keep both lists short;
      every entry is a hole in the guarantee.

      `GENERATED_PATHS` trusts the two provenance breadcrumbs by path, because
      their content is build-specific.

      `DOCKER_RUNTIME_PATHS` excludes five paths Docker injects into a
      container's rootfs at create time — `.dockerenv`, `dev/console`,
      `etc/hostname`, `etc/hosts`, `etc/resolv.conf`. **They are not in the
      image**: verified 2026-09-14 by inspecting the image layers directly, where
      none of the five appear. `docker export` is the only practical way to
      flatten a rootfs but it exports a *container*, so they came along and were
      being counted as base files. They cancelled out, so the arithmetic was
      never wrong — but the manifest claimed to describe the image while actually
      describing a container export, which a consumer re-deriving hashes from
      layers could not reproduce. A file planted at one of those five paths is
      now skipped; that is acceptable because Docker overrides all five at
      runtime, verified by building an image with `1.2.3.4 evil.example.com` at
      `/etc/hosts` and confirming the container sees Docker's file instead.

      Sub-task done 2026-09-15: `make push` carries `--provenance=mode=max`,
      which records build args and materials rather than just the build
      definition. It lives on `push` rather than `build` because attestations
      cannot be attached to a `--load`ed image — see the gotcha below.
- [ ] **Audit every build input for environment dependence.** Two have already
      been found by accident rather than by looking, both silently producing a
      different image digest for the same commit: `SOURCE_REPO` was the SSH
      remote locally and https under `actions/checkout`, and `VCS_REF` used
      `git rev-parse --short`, whose abbreviation length auto-sizes from the
      repository's object count. Both are fixed. The remaining inputs —
      `BITCOIN_VERSION`, `TARGET_TRIPLE`, `RUNTIME_BASE`, `MIN_GOOD_SIGS`,
      `BUILD_DATE` — are literals, a pinned digest, or derived from the commit
      timestamp, so they should be deterministic. **"Should be" is the problem:
      nothing tests it.** Do this as part of the item below, not separately.

      Note the distinction the rest of this file leans on. The image *contents*
      are genuinely environment-independent: `--network=none`, a digest-pinned
      base, and vendored inputs verified against a committed keyring.
      `make verify-contents` returns the same 1664 entries and zero unaccounted
      on a laptop and on a runner. What is **not** environment-independent is the
      build *tooling* — buildx driver and image store differ, which is what broke
      the attestation steps twice — and anything the Makefile computes from the
      local git checkout.

- [ ] **Reproducible rebuild agreement.** The strongest attestation claim
      available to this repo, and one `bitcoin/bitcoin` does not make: two people
      building the same commit independently get the same image digest. The
      pieces are already in place — `--network=none`, staged inputs,
      `SOURCE_DATE_EPOCH` pinned to the commit. What is untested is whether the
      digest actually lands identical; layer timestamps are the usual culprit.
      One such difference is already fixed: `SOURCE_REPO` came from
      `git remote get-url origin`, which is the SSH form on a dev box and https
      under `actions/checkout`. That put two different values in
      `org.opencontainers.image.source` for the same commit, and therefore two
      different digests. It is now normalised to https. Expect more of these —
      anything derived from the local environment rather than from the commit is
      a candidate.

      Try `--output type=image,rewrite-timestamp=true`, then have a second
      machine build the same commit and diff the digests. If it holds, publish
      the expected digest per tag and it becomes a claim anyone can check.

### Everything else

- [ ] **arm64.** `TARGET_TRIPLE=aarch64-linux-gnu` should work but is untested.
      Decide multi-arch manifest vs. separate single-arch tags. The pinned
      distroless digest is already a multi-arch index, so the base is not the
      blocker. A `TARGETARCH`->triple mapping inside the Dockerfile
      (`amd64`->`x86_64-linux-gnu`, `arm64`->`aarch64-linux-gnu`) is the
      conventional approach and lets buildx drive it rather than a make var.
- [x] **Confirm what the tarball actually ships.** Answered 2026-09-12 by
      unpacking the real 31.1 amd64 tarball.

      Top level: `bin/ libexec/ share/ README.md bitcoin.conf`. **There is no
      `lib/` directory at all.** `bin/` holds 7 binaries — `bitcoin` (the 2 MB
      unified wrapper), `bitcoin-cli`, `bitcoin-qt`, `bitcoin-tx`,
      `bitcoin-util`, `bitcoin-wallet`, `bitcoind`. `libexec/` holds
      `bitcoin-gui`, `bitcoin-node` (22 MB), `test_bitcoin`, confirming the 30.0
      layout change.

      **`bitcoind` is a real 17.8 MB standalone binary, not a wrapper**, and
      `ldd` shows it links only `libpthread`, `libm`, `libc` and `ld-linux` —
      **glibc only, no `libbitcoinkernel.so`**. Same for `bitcoin-cli`. So
      `SHIP_BINARIES="bitcoind bitcoin-cli"` is correct and self-contained, and
      nothing from `libexec/` is needed.

      **Consequence: the `lib/` handling in the Dockerfile was dead code** — the
      `if [ -d /unpack/lib ]` branch never fired and `LD_LIBRARY_PATH` pointed at
      an empty directory. Removed 2026-09-14 alongside the apt fix. Re-check on
      every minor version bump: this is a property of 31.1, not a guarantee, and
      `make smoke` is what catches it if a future release adds a shared library.
- [x] **Pin the runtime base by digest.** Done 2026-09-12.
      `gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f`
      in both the Dockerfile `ARG` and the Makefile. That digest is an OCI image
      **index** (amd64, arm64/v8, arm/v7, s390x), so multi-arch survives the pin
      — which the arm64 task will need. It is the `:nonroot` variant; the name no
      longer says so, which is the readability cost of pinning, hence the comment
      above the ARG. `scripts/check-pins.sh` now enforces that both files agree
      and that neither is on a floating tag. Verified end to end: a test image
      carrying the digest in its `org.opencontainers.image.base.name` label is
      resolved and fully accounted for by `verify-contents.sh` with no `BASE=`
      override.
- [ ] **STIG/hardening pass.** Distroless gets most of this for free, but the
      scanner wants explicit evidence. This is why the repo exists — do not let
      it slip behind the plumbing tasks.
- [ ] **Test that Dockerfile and verify.sh agree.** Partially covered as of
      2026-09-12: `scripts/check-pins.sh` (wired into `make verify`) asserts the
      *values* agree — `MIN_GOOD_SIGS` across all three files, `RUNTIME_BASE`
      across two — and is tested against injected drift in both. What remains is
      the *logic*: feed both a deliberately under-signed `SHA256SUMS` and assert
      both fail. Equal thresholds do not prove equal parsing.
- [ ] **Does an expired or revoked key's signature count toward our
      threshold?** Open question, not a known bug — do not assume either answer.
      What is known: verifying 31.1 emitted **4 `KEYEXPIRED` status lines**
      alongside 11 `VALIDSIG`, and Core's `verify.py` deliberately folds
      `EXPKEYSIG` and `REVKEYSIG` into its good tally (lines 185-193), so its 11
      and our 11 may agree for different reasons. What is NOT known: whether gpg
      emits `VALIDSIG` for a signature from an expired or revoked key, and so
      whether any of our 11 came from one. Those `KEYEXPIRED` lines may refer to
      unrelated keys in the keyring or to expired subkeys, and nothing has been
      traced. Determine it by construction: make a throwaway key, sign a file,
      expire the key, and see what `--status-fd` prints. Then decide policy — a
      revoked builder key almost certainly should not count, and if `VALIDSIG`
      alone cannot distinguish it, the parser needs `EXPKEYSIG`/`REVKEYSIG`
      handling in both places.
- [ ] **Annotate duplicate keys in `import-builder-keys.sh`.** Its `OWNER` map
      is keyed by fingerprint, so when two builder-key files carry the same
      primary key the second silently overwrites the first's name. guix.sigs has
      exactly one such pair today (`TheCharlatan.gpg` and `sedited.gpg`, same
      person), and the candidate list annotated it only as `# sedited` — the
      less recognisable of the two names, which is the opposite of helpful when
      the whole point of that comment is human recognition. Make it collect all
      names per fingerprint and emit `# TheCharlatan / sedited`.
- [ ] **Negative tests generally.** Tampered tarball, sig from an off-allowlist
      key, threshold of 5 when 6 is required, a binary swapped inside a test
      image so `verify-image.sh` is proven to catch it. A verification gate with
      no test proving it fails closed is decoration.
- [x] **CI.** `.github/workflows/ci.yml`, added 2026-09-14. Two jobs:
      `checks` runs `make check-pins` for fast drift feedback, and
      `verify-and-build` runs the whole chain — `verify`, `cross-check`,
      `build`, `smoke`, `verify-image`, `verify-contents` — on every pull
      request and push to main, ~14s of work plus the tarball download.

      Broader than the original plan, which was `verify` on PRs and the build
      only on tags. The full chain takes seconds, and **every bug found while
      writing this repo was a "never ran" bug**: the build had never succeeded,
      smoke could not fail, `verify-upstream` had the wrong path, the
      `base.name` label was empty. None were subtle once executed. Running
      everything on every PR is the whole point.

      Notes on the design:
      - CI downloads **only the tarball** (`make fetch-tarball`), leaving the
        committed `SHA256SUMS` and `.asc` alone. `make fetch` would re-download
        the sums and verify them against themselves. Cached on the expected
        tarball hash read out of the committed sums, so the cache invalidates
        exactly when the vendored version changes.
      - **No secrets in any job.** Signing needs a key and belongs in a separate
        tag-triggered workflow, so a pull request from a fork can never reach it.
      - Actions are **pinned by commit SHA**, not tag — the same reasoning as
        invariant 5 for the base image.
      - `make verify-upstream` is deliberately absent. It is valuable, but it
        depends on a third party's Docker Hub tag continuing to exist and keep
        its contents; that is someone else's availability and should not be able
        to turn this repo's CI red. Run it by hand when the claim matters.

## Where the signing key lives

Still undecided as of the v31.1 release, which shipped **keyless-only**. That is
a complete signing story on its own; the key pair adds offline verification, not
extra trust. Verified 2026-09-18: cosign
signatures are additive. Signing an already-published digest later with a
different key works — no republish, the digest does not change, and every key's
signature verifies independently. So publish keyless now and add a key whenever
the question is actually answered.

**The thing to be clear about before answering it.** A cosign private key stored
in GitHub Actions secrets is *not* a second, independent trust root. It is the
same trust root as keyless — "whoever controls this repo's workflows" — in a
form that happens to verify offline. Anyone who can merge a workflow can use the
secret. It buys air-gap verifiability, not independence from GitHub. Do not let
the repo claim otherwise.

The options, and what each is actually for:

- **GitHub Actions secret.** What `release.yml` assumes today. Right choice if
  the goal is an offline-verifiable signature for consumers who cannot reach
  Sigstore. Simple, automated, same trust root as keyless.
- **Signed out of band from a trusted machine.** The private key never touches
  GitHub. `make sign COSIGN_KEY=...` already works against a published image
  from anywhere, so this needs no code change — just registry write access and a
  deliberate step after each release. This is the option that produces a
  signature GitHub could not forge.
- **Hardware token or KMS** (`pkcs11:`, `awskms://`, `gcpkms://`,
  `hashivault://`). Key material is never extractable. The right answer if the
  signature ever needs to mean something to someone who does not trust you
  personally, and the wrong amount of machinery before then.

Whichever is chosen, `cosign.pub` belongs in the repo root — consumers need it
for the offline path the README documents, and a public key is exactly the thing
a repo is good at distributing.

### Set the signing secrets BEFORE the first tag

Ordering lesson from v31.1, which shipped keyless-only because `COSIGN_KEY` and
`COSIGN_PASSWORD` did not exist yet. Attaching the key-pair signature afterwards
by hand cost far more than the two minutes of setting the secrets up front, and
surfaced three separate obstacles that CI would never have hit: predicates are
gitignored so they are absent on a fresh clone or a second machine, a local
`docker login` usually carries only `read:packages` while signing needs write,
and the signing script forced an empty `COSIGN_PASSWORD` instead of prompting.
None of that exists in the workflow, where the predicates are already on disk in
the same job and `GITHUB_TOKEN` carries `packages: write`.

**Prefer re-running the release workflow over signing by hand.** Launch it from
the tag: `workflow_dispatch` takes no inputs, so the ref is the only source of
truth, and the non-tag guard refuses anything else.

### Adding the key pair, including to an image already published

Signatures are additive, so v31.1 does not need republishing. Verified
2026-09-18: signing an already-published digest with a new key leaves the digest
unchanged and both signatures verify independently.

```bash
# 1. Generate. Use a real password; cosign will prompt twice.
cosign generate-key-pair                 # writes cosign.key and cosign.pub

# 2. Commit ONLY the public half. check-pins.sh fails the build if a private key
#    ever becomes tracked — .gitignore does not stop `git add -f`.
git add cosign.pub && git commit -m "keys: publish cosign public key"
make check-pins                          # asserts no private key is tracked

# 3. Sign the EXISTING release. cosign attaches predicates, so all three must
#    be on disk first — this step does NOT regenerate them, and the first
#    attempt at this procedure failed for exactly that reason.
#
#    BEST: download the artifact the release run saved, so the key-pair
#    attestations are byte-identical to the keyless ones.
#      gh run download <run-id> -n release-31.1-predicates
#
#    Otherwise regenerate against the PUBLISHED image, not a fresh local build.
#    fetch-tarball first: the tarball is gitignored, so a fresh clone has no
#    copy, and `make verify` checks the vendored tarball's digest.
make fetch-tarball   VERSION=31.1
make verify          VERSION=31.1
make verify-contents IMAGE=ghcr.io/thefutoneng/bitcoin TAG=31.1
make sbom            IMAGE=ghcr.io/thefutoneng/bitcoin TAG=31.1

docker login ghcr.io
make sign IMAGE=ghcr.io/thefutoneng/bitcoin TAG=31.1 \
     COSIGN_KEY=./cosign.key

# 4. Prove the round trip as a consumer would.
make verify-sig IMAGE=ghcr.io/thefutoneng/bitcoin TAG=31.1 \
     COSIGN_PUB=./cosign.pub

# 5. For FUTURE releases, add repo secrets COSIGN_KEY (the private key file's
#    contents) and COSIGN_PASSWORD. release.yml picks them up automatically.
```

**The secret is named `COSIGN_KEY`, and the name is load-bearing.** The first
attempt used `COSIGN_PRIVATE_KEY` in the workflow while the secret was called
`COSIGN_KEY`; `HAS_KEY` evaluated false, the signing steps skipped, and the run
would have gone **green having published keyless-only**. A silent downgrade with
no error. There is now a "Signing plan" step that states which modes will be
used and raises a workflow warning when the key pair is absent.

Note the same name means two things: the *secret* holds the key's contents, the
*make variable* `COSIGN_KEY` is a path. The workflow writes one to produce the
other.

**If the key has a password, `COSIGN_PASSWORD` must also be a secret.** Both
secrets are set as of 2026-09-19. Verified against a password-protected key that
the whole CI path works non-interactively: `cosign public-key --key` reads
`COSIGN_PASSWORD` from the environment, `make sign` passes it through, and the
derived public key verifies all four checks. A **wrong** password is rejected
rather than silently skipped, and **no** password exits rc=1 rather than hanging
— there is no TTY in CI, so it cannot stall the job waiting for a prompt.

**Decide step 5 deliberately.** Putting the private key in GitHub secrets makes
future releases automatic, and makes the key the same trust root as keyless. Not
doing it keeps the key yours alone, at the cost of a manual step per release —
which is exactly steps 3 and 4 above, and they work from any machine with
registry write access.

## Gotchas

**`scripts/import-builder-keys.sh` is a bootstrap, not a trust anchor.** It
clones guix.sigs, which is where upstream's own tooling points and where key
additions are reviewable git commits. That is better than a keyserver lookup,
but the trust still comes from the human review step its header describes, not
from the script.

**`VALIDSIG` field 3 is the SIGNING key, not the primary key.** Found
2026-09-12 while bootstrapping, and it was a live bug in both parsers. Several
Core builders sign with a signing subkey — on 31.1 that is fanquake, Emzy,
willcl-ark and TheCharlatan. `import-builder-keys.sh` writes **primary**
fingerprints to the allowlist, so matching on `$3` silently discarded those four
valid signatures: 7 accepted instead of 11. It fails safe rather than open (valid
signatures get dropped, never forged ones accepted), but the margin over
`MIN_GOOD_SIGS=6` was 1 instead of 5, and two more builders adopting subkey
signing would have started failing good releases. Both parsers now read the last
field, which is the primary fingerprint:

```awk
awk '/^\[GNUPG:\] VALIDSIG/ { print (NF >= 12 ? $NF : $3) }'
```

Deduping on the primary also means one builder signing with two subkeys counts
once. **If anyone ever changes this back to `$3`, the threshold silently
tightens and good releases start failing.**

**`gpg --verify` exits 0 on one good signature.** That is why `verify.sh` and
the Dockerfile parse `--status-fd` output rather than checking the exit code. If
anyone ever simplifies that to an exit-code check, the threshold is gone. (This
is a note about our implementation, not a criticism of upstream tooling, which
handles this correctly.)

**Attestations are registry artifacts; `--load` cannot hold them.** buildkit
emits provenance and SBOM as separate manifests in an OCI index beside the
image. A `--load` into the classic docker image store has nowhere to put them
and buildx fails outright with `Attestation is not supported for the docker
driver`. This shipped in the first CI run and had passed locally for days,
because this machine has the **containerd image store** enabled
(`docker info` → `io.containerd.snapshotter.v1`) and GitHub runners do not. A
clean "works on my machine" difference in an environment nobody thinks to check.

`make build` therefore passes `--provenance=false --sbom=false` — it produces a
local image for smoke/verify-image/verify-contents, which need no attestations.
`make push` carries `--provenance=mode=max --sbom=true`, where they can actually
be stored. Do not add attestation flags back to a `--load` build.

**`make smoke` is not optional, and it must be able to fail.** The build can
succeed and produce an image whose binaries cannot load, or which cannot write
its datadir. There is no shell in the image to debug interactively, so smoke is
the feedback loop. It was decorative until 2026-09-14 — backgrounding
`docker run` and killing the client PID always exits 0 — and the first run that
could actually fail immediately found the `/data` ownership problem. If anyone
simplifies it back to a sleep-and-kill, it stops testing anything.

**Allowlist file format.** One fingerprint per line, optional `# comment` after
it. Both parsers strip inline comments and whitespace and uppercase the result —
keep them in sync if you change the format.
