# bitcoind-container

Builds a Bitcoin Core container image from signature-verified upstream release
binaries, on a base image we control, with artifacts vendored so the build is
hermetic and rebuildable offline.

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
Anyone who tells you otherwise — including earlier versions of this file — is
overselling it.

What this repo actually gives you:

1. **Base image control.** Theirs is Debian with a shell and a package manager
   in it. This one is distroless: no shell, no package manager, a far smaller
   CVE surface, and scanner evidence you own. This is not substitutable at any
   price, and it is the strongest single reason the repo exists.
2. **Offline rebuildability.** Vendored artifacts in git means you can rebuild
   from what is behind the wire. Pulling from Docker Hub means you cannot.
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
  it had never actually run. It has still not been run against a real image.)

Framed honestly: this is a **hardening and ownership** exercise. The provenance
was already fine.

## Invariants

1. **The container build has no network access.** `make build` passes
   `--network=none`. Every input comes from `vendor/`, committed to git. If a
   change requires network during build, the change is wrong.
2. **Threshold signature verification.** `SHA256SUMS` must carry at least
   `MIN_GOOD_SIGS` (**default 6**) valid signatures from keys on the allowlist
   in `keys/trusted-fingerprints.txt`. This is the same *mechanism* upstream
   tooling uses, at the same threshold `bitcoin/bitcoin` uses; it is table
   stakes, not a differentiator. The default lives in three places — Makefile,
   Dockerfile `ARG`, and `scripts/verify.sh` — change all three together. Do not
   reduce it to 1.
3. **Importable is not trusted.** Presence in `keys/` gets a key imported;
   presence in `trusted-fingerprints.txt` is what makes its signature count.
   Adding a fingerprint is a reviewed commit with a reason.
4. **The runtime base image is pinned by digest**, never by tag.
5. **Verification logic lives in two places** (`Dockerfile` and
   `scripts/verify.sh`) deliberately, so CI and the build agree. Change one,
   change the other. Task below to add a test that they match.

## Layout

```
Dockerfile                       two stages: verifier (throwaway) -> runtime (distroless)
Makefile                         fetch / verify / build / smoke / verify-image / sign / attest
scripts/fetch-release.sh         connected-machine: download release into vendor/
scripts/verify.sh                threshold sig check + digest check + provenance.json
scripts/verify-image.sh          extract binaries from any image, compare to verified tarball
scripts/import-builder-keys.sh   one-time bootstrap of keys/ from guix.sigs (read its header)
keys/                            armored builder pubkeys + trusted-fingerprints.txt
vendor/                          committed release tarball, SHA256SUMS, SHA256SUMS.asc
```

## Workflow

```bash
# one time, on a connected box, with human review of the output
scripts/import-builder-keys.sh
$EDITOR keys/trusted-fingerprints.txt.candidate   # prune to what you can corroborate
mv keys/trusted-fingerprints.txt{.candidate,}

# per version
make fetch VERSION=31.1
git add vendor/ && git commit -m "vendor: bitcoin core 31.1"
make build smoke verify-image
docker push ...
make sbom sign attest COSIGN_KEY=...
make digest          # publish this; consumers pin it
```

`make verify-image` is the regression test on the build: it pulls the binaries
back out of the image you just produced and proves they are byte-identical to
the tarball that cleared the signature threshold. If the Dockerfile ever starts
doing something clever, this catches it.

## What consumers need to know

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

### Do these first, immediately after the initial commit lands

These three are the priority. The two attestation items are what would make this
repo's guarantees genuinely stronger than what is already available elsewhere;
everything below this section is maintenance by comparison.

- [ ] **Run `make verify-upstream` once, after bootstrap.** Its `BIN_PATH` was
      wrong until 2026-09-12, so it has never executed successfully. It is not
      blocked on an upstream release — Core 31.1 shipped 2026-07-07 and
      `bitcoincore.org/bin/bitcoin-core-31.1/` has the tarball, `SHA256SUMS` and
      `SHA256SUMS.asc` today. It is blocked only on `keys/` being populated and
      `make fetch VERSION=31.1` having been run. This is the cheapest end-to-end
      exercise of `verify-image.sh` available, so do it first.
- [ ] **Contents-completeness attestation.** *This is the answer to "can we do
      attestation better than bitcoin/bitcoin", and the answer is yes.* Today
      `verify-image.sh` proves two named binaries are the right bytes; it proves
      nothing about what *else* is in the image, which is exactly the gap their
      docs warn about ("non-trivial to verify the authenticity of the bitcoin
      core binaries inside"). Close it with `scripts/verify-contents.sh`:
      `docker export` the runtime image to a flat rootfs, hash every regular
      file, then subtract (a) the file set of the pinned base image digest,
      exported the same way, and (b) the files we deliberately add — binaries
      and libs from the verified tarball, plus the provenance breadcrumbs.
      **Assert the remainder is empty, and that no base file was modified in
      place.** Emit the full manifest as JSON and attach it with `cosign attest`
      under its own predicate type, so a consumer can re-derive "these N files,
      these hashes, nothing else" offline from the image alone. Measured
      2026-09-12: `gcr.io/distroless/cc-debian12:nonroot` exports to 1788 tar
      entries / 1288 regular files, so the *base* set is too large to eyeball —
      but it is a fixed input pinned by digest, and the **delta** over it is the
      handful of files we add. That delta is what a reviewer reads. Also bump
      buildx from `--provenance=true` (mode=min) to `mode=max` while here, which
      records build args and materials for free.
- [ ] **Reproducible rebuild agreement.** The strongest attestation claim
      available to this repo, and one `bitcoin/bitcoin` does not make: two people
      building the same commit independently get the same image digest. The
      pieces are already in place — `--network=none`, vendored inputs,
      `SOURCE_DATE_EPOCH` pinned to the commit. What is untested is whether the
      digest actually lands identical; layer timestamps are the usual culprit.
      Try `--output type=image,rewrite-timestamp=true`, then have a second
      machine build the same commit and diff the digests. If it holds, publish
      the expected digest per tag and it becomes a claim anyone can check.

### Everything else

- [ ] **arm64.** `TARGET_TRIPLE=aarch64-linux-gnu` should work but is untested.
      Decide multi-arch manifest vs. separate single-arch tags.
- [ ] **Confirm what the tarball actually ships.** Run
      `tar -tzf vendor/bitcoin-*.tar.gz | grep -E '/(bin|lib)/'` and reconcile
      with `SHIP_BINARIES` in the Dockerfile. Core 30.0 really did change the
      layout (verified 2026-09-12 against the 30.0 release notes): it added a
      `libexec/` directory holding `bitcoin-node` and `bitcoin-gui`, moved
      `test_bitcoin` there out of `bin/`, and introduced a unified `bitcoin`
      wrapper command in `bin/`. **Our Dockerfile copies only `/unpack/bin/` and
      `/unpack/lib/` — it never looks at `libexec/`.** Confirm `bitcoind` in
      31.1 is still a standalone binary in `bin/` and does not exec anything out
      of `libexec/`, or the image ships a `bitcoind` that cannot start. Also
      check whether it dynamically links `libbitcoinkernel.so` — if so,
      `/usr/local/lib` must be populated and `make smoke` is what proves it
      resolves.
- [ ] **Pin the runtime base by digest.** Invariant 4 says the runtime base is
      pinned by digest, never by tag — but `RUNTIME_BASE` in both the Dockerfile
      and the Makefile is still the tag `gcr.io/distroless/cc-debian12:nonroot`.
      Resolved 2026-09-12 (amd64):
      `gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f`
      — re-resolve before pinning rather than trusting this line, since the tag
      moves. Pin it in both places. Re-run
      `make smoke verify-image` after any base bump; if the runtime UID ever
      changes, update the consumer facts above.
- [ ] **STIG/hardening pass.** Distroless gets most of this for free, but the
      scanner wants explicit evidence. This is why the repo exists — do not let
      it slip behind the plumbing tasks.
- [ ] **Test that Dockerfile and verify.sh agree.** Feed both a deliberately
      under-signed `SHA256SUMS` and assert both fail.
- [ ] **Negative tests generally.** Tampered tarball, sig from an off-allowlist
      key, threshold of 5 when 6 is required, a binary swapped inside a test
      image so `verify-image.sh` is proven to catch it. A verification gate with
      no test proving it fails closed is decoration.
- [ ] **CI.** `make verify` on every PR, `make build smoke verify-image` on
      tags. Keep the signing key out of PR-triggered runs.

## Gotchas

**`scripts/import-builder-keys.sh` is a bootstrap, not a trust anchor.** It
clones guix.sigs, which is where upstream's own tooling points and where key
additions are reviewable git commits. That is better than a keyserver lookup,
but the trust still comes from the human review step its header describes, not
from the script.

**`gpg --verify` exits 0 on one good signature.** That is why `verify.sh` and
the Dockerfile parse `--status-fd` output rather than checking the exit code. If
anyone ever simplifies that to an exit-code check, the threshold is gone. (This
is a note about our implementation, not a criticism of upstream tooling, which
handles this correctly.)

**`make smoke` is not optional.** The build can succeed and produce an image
whose binaries cannot load because the runtime base lacks a shared library.
There is no shell in the image to debug interactively, so the smoke test is the
feedback loop. This matters more as the base image changes, which it will.

**Allowlist file format.** One fingerprint per line, optional `# comment` after
it. Both parsers strip inline comments and whitespace and uppercase the result —
keep them in sync if you change the format.
