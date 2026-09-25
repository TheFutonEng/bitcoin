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
   in `keys/trusted-fingerprints.txt`.

   **"Valid" is precise here, and the precision was earned the hard way.** It
   means a `VALIDSIG` whose signature block carried no `EXPKEYSIG` or
   `REVKEYSIG`, counted by **primary** fingerprint so one signer with several
   subkeys counts once. Each half of that sentence was once wrong: the parsers
   matched signing-subkey fingerprints against a primary-key allowlist and
   silently dropped four good signatures, and they later counted expired ones.
   If this wording ever drifts back to just "valid signatures", the next
   implementer will reinvent one of those. This is the same *mechanism* upstream
   tooling uses, at the same threshold `bitcoin/bitcoin` uses; it is table
   stakes, not a differentiator. The default lives in three places — Makefile,
   Dockerfile `ARG`, and `scripts/verify.sh` — change all three together. Do not
   reduce it to 1.
4. **Importable is not trusted, and the two sets are kept equal anyway.**
   Presence in `keys/` gets a key imported; presence in
   `trusted-fingerprints.txt` is what makes its signature count. The check stays
   because it is what stops a stray key file from mattering — but we do not rely
   on it as a filter. `check-pins.sh` compares the keyring and the allowlist in
   **both** directions: a key in the keyring with no allowlist entry is inert,
   but an unexplained key inside the artifact the container build trusts is an
   auditability hole regardless. `keys/` holds **only** the allowlisted keys, because a
   non-allowlisted key cannot change the outcome and is just another blob gpg
   parses at verification time. Adding a signer is one reviewed commit carrying
   both the `.asc` and the fingerprint; `check-pins.sh` fails if an allowlisted
   fingerprint has no key file, since that failure is otherwise silent.
5. **Every base image is pinned by digest**, never by tag — the runtime base
   *and* the verifier base. The verifier stage is the one that actually checks
   the signatures, so a swapped image there is worth more to an attacker than
   one in the runtime: a `gpgv` emitting fabricated `VALIDSIG` lines defeats the
   threshold, and the resulting image looks legitimate. It sat on
   `debian:bookworm-slim` until 2026-09-20 because this invariant said "runtime
   base" and nobody re-read it against the Dockerfile. `check-pins.sh` now
   asserts all three references are digests.
6. **Verification logic lives in two places** (`Dockerfile` and
   `scripts/verify.sh`) deliberately, so a standalone check and the image build
   agree. Change one, change the other. Both are run by CI on every PR.

   **Do not call these two implementations "independent".** They are the same
   hand-written parser duplicated, so they share their bugs — demonstrated
   twice: the `$3`-versus-primary-fingerprint bug was present in both, and so
   was counting expired signatures. Duplication buys defence against one
   *copy* being edited, not against the logic being wrong. The only real
   independence in this repo is `make cross-check`, which runs Core's own
   `verify.py` against the same artifacts and compares verdicts.

   `tests/test-threshold.sh` (via `make test`) is what keeps the two copies
   honest in the meantime: it feeds both the *same* fixtures and asserts they
   report the *same count*, so a change to one that the other does not get
   fails CI rather than waiting for a release to expose it.

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
scripts/verify-reproducible.sh   prove this commit builds the same image bytes anywhere
                                 (uses a docker-container builder on a pinned buildkit)
tests/test-threshold.sh          negative tests: both threshold gates, same fixtures, must agree
tests/test-config.sh             config and the datadir actually reach the container
examples/bitcoin.conf            commented teaching file AND the fixture test-config.sh runs
reproducible-digest.txt          the canonical image manifest digest CI checks every PR against
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

## Releasing

A release is a signed git tag. Everything else is automatic, and everything that
could publish the wrong thing is guarded — but the guards only run at tag time,
so read this before cutting one.

### Before you tag

```bash
git checkout main && git pull --ff-only
git status --porcelain          # must be empty
make print-version              # e.g. 31.1
make print-revision             # e.g. 1
```

**The tag must be `v<version>-<revision>` using exactly those two values.**
`release.yml` re-derives them from the tag and refuses to publish if they
disagree with the tree. That check exists because nothing else catches the
mismatch: the build would succeed, the image would be labelled from the Makefile
and published under the tag, and a consumer who pinned the digest would only
ever see the label.

```bash
make repro-digest               # note this value
```

Write that digest down. The release prints the same figure into its job summary;
if they match, the published image is bit-for-bit what this commit builds, on
two different machines. That is the claim, and comparing is how you check it.

### Tag and push

```bash
git tag -s v31.1-1 -m "bitcoin core 31.1, image revision 1"
git push origin v31.1-1
```

Signed, because the tag is the trust root for the keyless signature — the
identity binds to `refs/tags/<tag>` on this repository.

### What the workflow does, in order

Worth knowing so a failure tells you where you stand:

1. **Refuse a non-tag ref**, then **resolve version and revision** and compare
   them to the tree. *Nothing has been published yet.*
2. **Install cosign and syft**, pinned by version and verified by hash.
3. **Set up a docker-container builder** on the pinned buildkit.
4. **Signing plan** — fails outright if `COSIGN_KEY` is absent, unless
   `allow_keyless_only=true` was passed. This is the guard against a silent
   keyless-only downgrade.
5. **The whole verification chain**: fetch-tarball, verify, cross-check, build,
   smoke, verify-image, verify-contents. *Still nothing published.*
6. **Log in to GHCR and push.** ← the first irreversible step.
7. **Re-verify the PUSHED image** — verify-image and verify-contents against
   what is actually in the registry, not the local build.
8. **Prove the published image is reproducible** — rebuilds the tag and compares
   the image manifest inside the published index.
9. **SBOM**, then **sign keyless**, then **sign with the key pair**.
10. **Verify the signing chain round-trips** — signature plus all three
    attestations, in whichever modes were used.
11. **Publish the digest** to the job summary, with the reproducible image
    manifest digest and the command to check it.

Steps 1–5 fail safely: nothing reached the registry. Steps 7–8 fail with an
**unsigned image already public**, which is recoverable but needs a decision.

### After it goes green

```bash
# From a clean shell with no credentials — as an outsider, not as the runner.
cosign verify ghcr.io/thefutoneng/bitcoin:31.1-1 \
  --certificate-identity-regexp '^https://github\.com/TheFutonEng/bitcoin/\.github/workflows/release\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

make verify-repro-published TAG=31.1-1
```

A workflow verifying its own signature proves the plumbing. An outsider
verifying it with the published regexp proves the claim. **Do the second one
after every release**, and compare the job summary's digest against the
`make repro-digest` value you wrote down.

### When a release fails

The rule the versioning scheme exists to make possible:

- **Nothing reached the registry** (steps 1–5): delete the tag, fix, re-tag the
  same name. No artifact ever carried it.
  ```bash
  git tag -d v31.1-1 && git push origin :refs/tags/v31.1-1
  ```
- **Anything was published** (step 6 onward): **do not move the tag.** Bump
  `REVISION`, commit, and tag `v31.1-2`. A moved tag means two different
  artifacts under one name, which is exactly what immutable revision tags are
  for. This is a change from how v31.1 was handled, when moving the tag was the
  only option available.

**To re-run a release, use `workflow_dispatch` launched FROM the tag**, not from
a branch. It takes no inputs other than `allow_keyless_only` precisely so the
ref is the only source of truth. Note the trap found on v31.1: dispatch executes
the workflow file **as it existed at that ref**. If the bug you are re-running
to fix is in `release.yml` itself, re-running from the old tag re-runs the bug.

## What consumers need to know

- **Tags are `<bitcoin version>-<image revision>`**, Debian's
  `upstream_version-debian_revision` model: `31.1-1`. `VERSION` in the Makefile
  is the upstream Bitcoin version and selects the tarball; `REVISION` names the
  packaging and starts at 1 for each Bitcoin version. `TAG` is the two joined,
  and `org.opencontainers.image.version` carries the same value — **which is the
  point**: tags live in the registry and are not part of the artifact, so an
  image pulled by digest would otherwise not say which revision it is. The two
  live in the Makefile and the Dockerfile; `check-pins.sh` asserts they agree,
  and `release.yml` refuses a tag that disagrees with the tree.

  No bare version tags. `ghcr.io/thefutoneng/bitcoin:31.1` exists and is a
  legitimate signed image, but it predates the scheme and is the only one.
  Retagging it `31.1-0` was considered and rejected: it was built when the
  version label was just `31.1`, so it would have been tagged `31.1-0` while
  labelled `31.1`, permanently, because the label is inside a signed digest.
  Starting at `31.1-1` keeps every tag's label matching its name, which is worth
  more than closing a one-image gap in the numbering.
- The published image is **`ghcr.io/thefutoneng/bitcoin`** — named `bitcoin`,
  not `bitcoind`, to match what every other Bitcoin Core container is called.
  The binary inside is still `bitcoind`, and the attestation predicate types
  stay `bitcoind-*` because they describe the daemon payload rather than the
  image. That asymmetry is deliberate; do not "fix" it. Changing a predicate
  type after anything is published breaks verification for every image already
  signed with the old one.
- Runs as UID/GID **65532:65532** (distroless `nonroot`). Changes if the runtime
  base changes.
- Datadir `/data`, declared `VOLUME`, **and present in the image owned by
  65532** so a fresh named or anonymous volume is usable with no preparation.
  Docker seeds a new volume's ownership from the mount point in the image; /data
  did not exist in the distroless base, so before 2026-09-23 a plain
  `docker run` with no arguments and no mount died on "Unable to open settings
  file /data/settings.json.tmp for writing". There is no shell, so chown-ing in
  an entrypoint script — what `bitcoin/bitcoin` does with gosu — is not
  available. Creating the directory at build time is the only mechanism left.
  It does **not** help a bind mount, where the host's ownership wins, and is
  moot under Kubernetes where `securityContext.fsGroup` chowns at mount time.
- **`ENTRYPOINT` carries `-datadir=/data -printtoconsole`; `CMD` is empty.** The
  distinction is not cosmetic: Docker REPLACES CMD with user arguments but
  PREPENDS ENTRYPOINT to them. With the flags in CMD — as they were until
  2026-09-23 — any argument a consumer passed silently dropped the datadir, so
  `docker run -v vol:/data image -txindex=1` wrote the chain to
  /home/nonroot/.bitcoin on the container layer, ignored the mounted volume,
  started normally and lost everything on `--rm`. Both flags stay overridable,
  measured: Core takes the last duplicate on the command line, so
  `-datadir=/other` wins and `-noprinttoconsole` silences it.
- **There is no `BITCOIN_DATA`, and there should not be.** It was set until
  2026-09-23 and did nothing — bitcoind does not read it. It is a convention
  from `bitcoin/bitcoin`, whose entrypoint *script* expands it into `-datadir=`.
  Both READMEs listed it as a consumer fact. Verified inert by running with
  `BITCOIN_DATA=/elsewhere`: the datadir did not move.
- **No `bitcoin.conf` ships in the image.** Decided 2026-09-23. Upstream's
  tarball contains one, but it is 24,789 bytes of which exactly five lines are
  not comments or blank, and all five are empty network section headers — a
  template, not a configuration. Baking one in would be another file to keep
  accurate, un-overridable without shadowing it, and another entry in the
  contents manifest. `examples/bitcoin.conf` carries the teaching instead, and
  `tests/test-config.sh` keeps it honest.
- Ports: 8332 RPC, 8333 P2P, 28332/28333 ZMQ.
- Ships `bitcoind` and `bitcoin-cli` only.
- Provenance breadcrumbs at `/usr/local/share/bitcoind-provenance/`, plus a
  cosign attestation. **These two files are trusted by path, not by hash** —
  their content is build-specific, so `verify-contents.sh` does not check it.
  Replacing them would not fail verification. They are breadcrumbs, not
  evidence; the attestations are the evidence.

## Open work

### External security review, 2026-09-20

An independent agent reviewed this repository against the claims below. It is
worth reading its conclusions as a corrective to this file's tone: two of its
findings were high-severity and both were real.

**`verify-contents.sh` failed open.** The `docker export` pipeline ended in
`|| true`, so an export failure produced an empty inventory, compared cleanly
against an empty base inventory, and reported "every file is accounted for"
with exit 0. The script carrying this repo's most distinctive claim would
have passed while unable to read the thing it was verifying.

**Expired signatures counted toward the threshold** — see the closed item
below.

Both fixed, each reproduced first. Also fixed: the keyring was verified one way
only, a release could publish keyless-only, the guix.sigs fallback took a
majority vote when builders disagreed, and shellcheck had never been run.

The review's most useful work was arguably not the code findings but the
documentation ones, and they are the reason for the corrections in the
invariants above: **"two independent implementations" was misleading**, and
**"every file is accounted for" overstated what the path exclusions allow**. In
a repo whose entire purpose is to be believed, a doc that overstates a
guarantee is a real defect, not a cosmetic one.

What it got slightly wrong, for the record: it described the keyless-only
downgrade as "silent" when a warning already existed, and it measured the
expired-key exposure against the 38-key bootstrap keyring rather than the
10-key allowlist that actually gates, where the exposure was zero. Neither
changes the finding; both are worth noting because precision about impact is
what separates a useful review from an alarming one.

### Mutation testing, 2026-09-21 — how the threshold suite was validated

A passing test proves nothing until it has been shown it can fail. After
`tests/test-threshold.sh` went green, every gate it covers was deliberately
broken, one mutation at a time, in a throwaway `git archive` of HEAD, and the
suite was re-run against each. **13 mutants, 13 caught** — `$3` instead of the
primary fingerprint, dropped `sort -u`, threshold weakened to 1, dropped
`EXPKEYSIG` handling, dropped allowlist intersection, dropped `NEWSIG` scoping,
each in both the Dockerfile and verify.sh.

That number is the point, but the process is the value: **the first version of
the suite was green and caught only 9 of 13.** Three things it could not see,
all found by mutation and none by reading it:

1. **Dropping the allowlist intersection changed nothing.** `keys/` holds
   exactly the allowlisted keys, so the signer set and the allowlist are always
   identical on real data and `comm -12` is a no-op. Invariant 4 — "importable
   is not trusted" — was completely untested, and could have been deleted from
   both gates silently. Fixed by minting a key that is in the keyring and not on
   the allowlist, which is a state the repo otherwise refuses to be in.

2. **Dropping `EXPKEYSIG` handling changed nothing**, because every allowlisted
   signer of 31.1 is current. The fix for the review's second HIGH finding had
   no test that could fail. Fixed by minting a key and letting it expire.

3. **Dropping the `NEWSIG` reset changed nothing** — and this one is the
   sharpest. Without it the `bad` flag latches on the first `EXPKEYSIG` and
   every *subsequent* signature is discarded too. The fixture put the expired
   packet last, so nothing followed it and the bug was invisible. **An ordering
   assumption in the fixture, not in the code.** Fixed by a second fixture with
   the expired signature first and a full quorum after it, asserted to be
   ACCEPTED. That case is also the realistic one: the day a Core builder's key
   lapses, upstream ships exactly that bundle, and a latched flag would reject a
   release ten current builders signed.

A fourth problem surfaced from running the suite twice rather than once:
buildkit caches successful steps and not failing ones, so on the second run the
accept case came back `CACHED` with no output to parse. The asymmetry points
exactly the wrong way — the one case that must keep passing is the one whose
result gets reused, and CI warms that cache with `make build` earlier in the
same job. `--no-cache` on the test's build is load-bearing.

**Do this for every gate before believing its test.** Reading a test tells you
what it intends to check. Breaking the code tells you what it actually checks,
and on this evidence the two differ about a third of the time.

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

**Read this before picking something up.** Publishing and proving are finished:
v31.1-1 is out, signed both ways, fully attested, and reproducible from a second
machine. What remains is in a deliberate order, and the order matters more than
it looks.

1. **arm64** (in *Everything else* below). Take this first. It is the last open
   item that changes what the artifact *is* rather than what is proven about it,
   and everything downstream inherits the decision. Built, tested and
   reproducible in CI as of 2026-09-25; what remains is the release — see the
   arm64 item for the step list.
2. **STIG/hardening evidence.** Take this *after* arm64, not before. The
   evidence is scanner output against a specific image, so producing it and then
   changing the architecture — or moving to a multi-arch index — invalidates it
   and you do the work twice. That ordering is the whole reason arm64 goes
   first, and it is not obvious from either item on its own.
3. **Negative tests for the remaining gates.** Cheapest of the group, the
   pattern is established in `tests/`, and the reproductions to codify are
   already named.
4. **Rebuild-from-published-image.** Closes the real operational gap: a
   distroless CVE when upstream has withdrawn the release.

Items 1 and 2 are sequenced. Items 3 and 4 are independent of everything and can
be picked up at any point.

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
- [x] **First real publish — v31.1, 2026-09-19.** Published twice; the second
      run is what `:31.1` points at.

      ```
      ghcr.io/thefutoneng/bitcoin@sha256:b36d45e23e2dd5499660b2d3b184d28069c14577a2330334de6ad186d2459fd2
      ```

      **Both signing modes verify** from a clean shell with no credentials —
      signature plus provenance, SBOM and contents manifest, keyless *and*
      against the committed `cosign.pub`. Eight checks. The key-pair path had
      never worked before: the README documented a `cosign verify --key` command
      with no key-pair signature behind it.

      The first run (`sha256:35c21e69…`) published keyless-only, because the
      signing secrets did not exist yet. **Decided 2026-09-23: it stays.** It is
      untagged, superseded, and nothing points at it, so every path a consumer
      actually takes leads to a newer revision. It remains pullable by digest
      and verifies keyless — it is a legitimate image we built, signed one way
      instead of two, not something to hide. Deleting it was considered purely
      as tidiness; do not re-open it as though it were a security question. Re-running required moving the tag: a
      `workflow_dispatch` from `v31.1` would have executed the workflow file
      **as it existed at that ref**, which still read the wrong secret name and
      would have published keyless-only again, silently. Moving the tag to the
      fixed `main` both corrected the ref and re-triggered `push: tags`.

      The digest necessarily changed — `VCS_REF` and `BUILD_DATE` both derive
      from the commit, and it was a different commit. That is not a
      reproducibility failure; same commit still means same digest.

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

- [x] **v31.1-1, 2026-09-23 — the first release under the revision scheme, and
      the first reproducible one.**

      ```
      ghcr.io/thefutoneng/bitcoin:31.1-1
      index sha256:0dc05d92fc66…3649e
      image sha256:bbd7da4f3525…ae2c1   <- the reproducible half
      ```

      Same upstream binaries as v31.1; what changed was the packaging, which is
      the case the `<version>-<revision>` scheme exists to name.

      Four pieces of machinery ran for the first time, none of which a pull
      request can exercise: the tag-versus-tree guard, `make push` with the
      explicit `--output` and `rewrite-timestamp`, the pinned-buildkit release
      builder, and `verify-repro-published`. All 24 steps passed first time.

      Verified from a clean shell as an outsider, not from the runner: keyless
      and key-pair signatures, plus all three attestations. `key pair: yes` in
      the signing plan, so no silent keyless downgrade.

      **The release also found the buildkit cache bug** — see the gotcha below.
      The digest printed by `make repro-digest` before tagging did not match the
      one the runner published, which looked like a reproducibility failure and
      was in fact a bug in `verify-reproducible.sh`. With `--no-cache` the
      laptop reproduces the published image exactly. So the first release under
      this scheme is also the first to have its reproducibility confirmed by a
      second machine, which is the whole point of the claim:

      ```
      make verify-repro-published TAG=31.1-1
      OK — the published image is bit-for-bit this commit
      ```

      Lesson worth keeping: the pre-tag `make repro-digest` value is what caught
      it. Writing that number down and comparing it against the job summary is
      not ceremony — it is the only step in the procedure that compares two
      machines, and it earned its place on the first run.

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
      `BITCOIN_VERSION`, `TARGETARCH`, `RUNTIME_BASE`, `MIN_GOOD_SIGS`,
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

      **Largely answered 2026-09-22 by `make verify-repro`, which turns "should
      be deterministic" into a gate.** Anything environment-dependent that
      reaches the image now changes the digest and fails CI. What that check does
      *not* cover, and what keeps this item open: it deliberately fixes `VCS_REF`,
      `BUILD_DATE` and `SOURCE_REPO` to placeholders rather than exercising the
      real ones. Those three are the inputs that were actually buggy before, so
      the gate covers everything except the category with the known history.
      Reading them from the commit is what makes them safe; a regression there
      would show up as `verify-repro-published` failing at release time rather
      than on the PR.

- [x] **Reproducible rebuild agreement — done 2026-09-22.** Two people building
      the same commit get the same image. `scripts/verify-reproducible.sh`,
      `make verify-repro`, and `reproducible-digest.txt` committed and checked by
      CI on every pull request.

      **Layer timestamps were the whole problem, exactly as suspected.** Two
      builds of the same commit minutes apart differed, and the only difference
      anywhere in the layers was file mtimes: the binaries carried the wall-clock
      time of the build. `SOURCE_DATE_EPOCH` was already exported and already
      honoured — for the image *config*. It does nothing to layer contents. The
      flag that does is `rewrite-timestamp=true` on the exporter. With it, four
      independent builds produced one digest.

      **What is reproducible, precisely.** The **image manifest** digest.
      Verified identical across buildkit v0.29.0 (embedded, docker driver) and
      v0.32.2 (docker-container driver), cached and `--no-cache`, exported as an
      OCI layout and pushed to a real registry, and with attestations attached
      and not. For commit `8be4d327` that digest is
      `sha256:be82167d…1dac`, every time.

      **What is NOT, and never can be: the OCI index digest — which is the thing
      consumers pin.** The index wraps the image manifest together with the
      attestation manifest, and the attestations contain irreducibly per-build
      values: buildkit stamps `startedOn`, `finishedOn` and a random
      `invocationId` into the SLSA provenance, and syft stamps a `created` time
      and a random UUID `documentNamespace` into the SBOM. Measured: the image
      manifest was byte-identical across runs while the index digest changed
      every single time.

      That distinction is load-bearing and nobody had noticed it was there. This
      file previously said "publish the expected digest per tag and it becomes a
      claim anyone can check" in one place and "that digest is the OCI index …
      which is what consumers pin" in another. Both sentences were reasonable;
      together they described something impossible. **The claim is "the image
      inside the published index is reproducible", not "the published digest is
      reproducible".** Do not let it drift back.

      **Why the checked digest is a CANONICAL build.** The digest depends on
      `VCS_REF` and `BUILD_DATE`, which change with every commit, so an expected
      digest for the current commit can never be committed alongside it — the
      file would have to contain a hash of itself. `verify-repro` therefore
      builds with fixed placeholders, making the digest a function of the things
      that matter: Dockerfile, verified tarball, accepted signer list, pinned
      base. Determinism with real args follows, because the args reach the image
      only as label strings and are themselves derived from the commit.

      **The cross-machine half is what CI provides.** `reproducible-digest.txt`
      is generated on a dev box and asserted on a GitHub runner. Running the
      build twice on one machine would only prove it is not random; comparing
      against a value produced somewhere else is the actual claim.

      The first CI run proved the point immediately, though not the way intended:
      it failed with `OCI exporter is not supported for the docker driver`,
      because the check had only ever run on a machine with the containerd image
      store. The digest was right; the script could not execute anywhere else.
      A gate that has only run in one environment is not a cross-environment
      gate, and there is no way to find that out except to run it in another.

      **v31.1 cannot be retrofitted.** It was built before `rewrite-timestamp`,
      so its layers carry `2026-09-19 14:20` mtimes — confirmed by exporting the
      published image. The claim starts at the next release. `release.yml` now
      runs `make verify-repro-published` before signing and prints the
      reproducible digest into the job summary, so each release ships the value
      an outsider needs to check it.

### Everything else

- [ ] **arm64. Do this before the STIG pass** — see the ordering note at the top
      of *Do these next*. It is the last open item that changes what the artifact
      is, and scanner evidence produced against amd64 does not survive an
      architecture change.

      **Decided 2026-09-25: one multi-arch OCI index, and the reproducibility
      claim covers both platforms** — a digest per platform, not "amd64 only".
      It ships as a new revision (`31.1-2`): same upstream binaries, different
      packaging, which is exactly what `-<revision>` exists to name.

      **Step 1, build support — done 2026-09-25**, measured on an amd64 host:

      - The Dockerfile maps `TARGETARCH` to the triple; `TARGET_TRIPLE` is gone
        as a build arg. It had to go: one `--platform a,b` build cannot pass a
        different build arg per platform. An unmapped arch fails the build.
        The Makefile derives `TRIPLE` from `PLATFORM` and rejects `TRIPLE=` on
        the command line. The table lives in four files; `check-pins.sh`
        asserts they agree, because swapping one entry was tried and the build
        **succeeded** with amd64 binaries in an arm64 image.
      - The verifier stage runs on `$BUILDPLATFORM`. gpgv never runs under
        emulation, and cross-building needs no binfmt at all — this host has
        none registered for aarch64 and builds arm64 fine.
      - **The amd64 canonical digest did not move** (`75d0d79b…`), so the
        refactor is behaviour-neutral for everything already published.
      - arm64: deterministic across two builds; `verify-image` MATCH
        (`bitcoind 1b279e03…`, `bitcoin-cli 815c0969…`); `verify-contents`
        1659 base + 2 + 2 = **1663**, zero unaccounted. One fewer than amd64
        because distroless ships `libmvec.so.1` on x86_64 only — explained,
        not just observed. Threshold suite 35/35 on both triples.
      - `verify-contents.sh` compared an arm64 image against the **amd64**
        base until this change — `docker create` on an index takes the host's
        variant — and flagged every arch-specific file MODIFIED. It now
        inventories image and base for one platform, from `PLATFORM=` or the
        image itself. `verify-image.sh` takes `PLATFORM=` too.
      - The arm64 tarball links only glibc and has no `lib/`, same as amd64.

      **Steps 2 and 3, CI and per-platform reproducibility — 2026-09-25.**
      One PR, because they could not be separated: an arm64 CI leg running
      `verify-repro` needs an arm64 expected digest.

      - `verify-and-build` is a matrix over amd64 (`ubuntu-latest`) and arm64
        (`ubuntu-24.04-arm`), each running the whole chain **natively** —
        smoke and test-config execute binaries, and an emulated pass would
        only prove the binary runs under an emulator. `fail-fast: false`, so
        which leg failed is visible. The workflow gets the tarball name from
        `make print-triple` rather than holding a fifth arch table.
      - `reproducible-digest.txt` holds one `<platform> <digest>` line each.
        `--write` builds every platform in `ALL_PLATFORMS`; compare checks
        `$PLATFORM` and fails on a missing line rather than falling back.
        amd64 stayed `75d0d79b…`; arm64 is `3315fa74…`.
      - **The arm64 value is cross-built on an amd64 host and asserted on a
        native arm64 runner** — two CPU architectures agreeing on the bytes,
        which is a stronger claim than the amd64 one.
      - `--against` now selects the published manifest by os/architecture. It
        took "the entry that is not unknown/unknown", which is one image in a
        single-platform index and a concatenation of several in a multi-arch
        one. Checked against the real `31.1-1` index: amd64 yields
        `bbd7da4f…`, arm64 yields nothing and fails.
      - Every pinned image — both bases, buildkit, test-config's cleanup
        image — was confirmed to be a multi-arch index including arm64 before
        the arm64 runner could discover otherwise.

      **Remaining, in order:**

      4. **Release.** `make push` builds `linux/amd64,linux/arm64` into one
         index. Re-verification must pull each platform **by digest** from the
         pushed index. The current "Re-verify the PUSHED image" step has never
         read the registry: `make build` left the same tag in the local store,
         so `docker create` used the local copy. v31.1-1 is still sound —
         `verify-repro-published` did read the registry, and matched — but
         that step claims more than it does, and fixing it is part of this.
         Contents manifests and SBOMs are per platform.
      5. **Docs.** README consumer section, and the `31.1-2` release itself.

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
- [ ] **STIG/hardening pass. Do arm64 first** — see the ordering note at the top
      of *Do these next*. The evidence is scanner output against a specific
      image, so producing it and then changing the architecture, or moving to a
      multi-arch index, means doing the work twice.

      Distroless gets most of this for free, but the scanner wants explicit
      evidence. This is why the repo exists — do not let it slip behind the
      plumbing tasks. The plumbing is finished as of 2026-09-23, so "after the
      plumbing" now means "after arm64", and nothing else.
- [x] **Test that Dockerfile and verify.sh agree — done 2026-09-21.**
      `check-pins.sh` had covered the *values* since 2026-09-12; `make test`
      now covers the *logic*. `tests/test-threshold.sh` splits the real
      committed `SHA256SUMS.asc` into its 11 individual signature packets with
      `gpgsplit`, reassembles them into fixtures with a known number of
      acceptable signers, and feeds each fixture to **both** gates — the real
      `scripts/verify.sh` and the real `Dockerfile` verifier stage, built with
      `--target verifier`. 35 assertions, ~14s, wired into CI.

      The headline assertion is not "both rejected" but **"both reported the
      same count"**. A verdict is one bit and hides disagreement; the count is
      what separates two parsers.

      Seven fixtures, and note what each is for. `at-threshold` (accept) exists
      because a suite of rejection tests passes against a parser that rejects
      everything. `under-threshold` is the named ask. `duplicate-signer` repeats
      one signer to hold `sort -u` in place — gpgv really does emit a VALIDSIG
      per copy. `unknown-padding` adds a packet from a key absent from the
      keyring. `untrusted-in-keyring` and the two expired cases each need a
      throwaway key, below.

      **Two cases mint an ephemeral key in a temp GNUPGHOME, and they have to.**
      `keys/` holds exactly the allowlisted keys (invariant 4), so on real data
      the signer set and the allowlist are identical and the intersection is a
      no-op — `comm -12` could be deleted from both gates and nothing would
      notice. `untrusted-in-keyring` puts a genuine, verifiable, *non*-allowlisted
      key in the keyring, which is the only way to actually exercise "importable
      is not trusted". Likewise all 10 allowlisted signers of 31.1 are current,
      so the `EXPKEYSIG` handling has nothing to act on until a key is made to
      expire. The key material is ephemeral and never leaves the temp directory.

      The test never mutates `upstream/`: it copies into a throwaway repo root
      and a throwaway build context. A crash mid-run must not be able to leave
      the real trust anchor replaced by a five-signature fixture.
- [x] **Answered 2026-09-20: expired and revoked signatures no longer count.**
      The question was whether gpg emits `VALIDSIG` for a signature from an
      expired key. It does — **both** `EXPKEYSIG` and `VALIDSIG`, verified by
      construction with a key given a 2-second lifetime — so a parser reading
      only `VALIDSIG` counted them. Both parsers now scope a flag by `NEWSIG`,
      which begins each signature block, and skip that signature.

      Treated as policy, not just a fix. A signature made while a key was valid
      is arguably still evidence; it is rejected anyway, because the threshold
      is meant to count people who *currently* vouch for the bytes. It costs
      nothing today — all 10 allowlisted signers of 31.1 are current, and the
      accepted count is 10 either way.

      Note for anyone re-measuring this: the "4 `KEYEXPIRED` lines" recorded
      here earlier came from the 38-key bootstrap keyring, not the pruned
      10-key allowlist. Against the allowlist there are none. Measure against
      what actually gates, not against what happens to be imported.

- [ ] **Annotate duplicate keys in `import-builder-keys.sh`.** Its `OWNER` map
      is keyed by fingerprint, so when two builder-key files carry the same
      primary key the second silently overwrites the first's name. guix.sigs has
      exactly one such pair today (`TheCharlatan.gpg` and `sedited.gpg`, same
      person), and the candidate list annotated it only as `# sedited` — the
      less recognisable of the two names, which is the opposite of helpful when
      the whole point of that comment is human recognition. Make it collect all
      names per fingerprint and emit `# TheCharlatan / sedited`.
- [x] **Config and datadir handling — `tests/test-config.sh`, 2026-09-23.**
      Seven assertions, ~7s, in `make test`. Written because two consumer-facing
      defects were found by *asking how configuration is passed* and then
      testing the answer rather than reading the Dockerfile.

      The first: arguments replaced `CMD`, so any flag a consumer passed moved
      the datadir off their volume, silently. Proven by mounting a host
      directory, passing `-regtest`, and finding the directory **empty**
      afterwards — the log looked perfectly healthy throughout, which is why an
      assertion on the log would have missed it.

      The second is subtler and shapes the whole design of the example config:
      **Bitcoin Core does not fail on an unknown option in a config file.** It
      logs `Ignoring unknown configuration value` and continues. So a stale
      example would leave a user's settings quietly doing nothing. Booting it
      proves it parses; only checking every option name against
      `bitcoind -help` **from the image under test** proves it is still true.
      Mutation-tested: a bogus *commented* option produced no runtime warning at
      all and was caught solely by the name check.

      Note `bitcoind -help` is **not exhaustive** — `-regtest` works, is used
      throughout this repo, and appears only as an allowed value of `-chain`.
      The test carries a short exception list; anything added to it needs
      evidence, not a hunch.

      Three mutants, all caught: flags back in `CMD` (3 assertions fired),
      `/data` not created (the fresh-volume assertion), a bogus option in the
      example (the name check).

- [ ] **Negative tests for the remaining gates.** The threshold is now covered
      by `make test` (above). The rest are not, and each has a reproduction that
      was demonstrated once by hand and then lost: a `docker` shim whose
      `export` fails (proves `verify-contents.sh` no longer passes on an
      unreadable image), a generated key planted in the keyring (proves
      `check-pins.sh` catches extras), a tampered image pushed to the same tag
      (proves signature verification binds to the digest), verification with the
      wrong public key, a planted file in the image, and injected pin drift.

      `tests/` and the `test` target already exist, so adding one is a file plus
      a prerequisite. The pattern to copy from `test-threshold.sh`: build the
      fixture from real artifacts, run the **real** gate, and assert on the
      reason for the failure rather than on the exit code.

- [ ] **Mutation-test the other gates the way the threshold was.** See the
      mutation-testing section above — the technique found two blind spots that
      review did not.
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

**`SOURCE_DATE_EPOCH` does not rewrite layer timestamps. `rewrite-timestamp`
does.** The easy mistake, and the reason this repo believed it was close to
reproducible for a week. buildkit applies `SOURCE_DATE_EPOCH` to the image
*config* — the `created` field and the history entries — and leaves the mtimes
inside the layer tars at wall-clock time. Both builds then have a matching
`created` and completely different layer digests. The exporter option
`rewrite-timestamp=true` is what rewrites the tar entries. `make push` and
`scripts/verify-reproducible.sh` both pass it; `make build` cannot, see below.

And the epoch has to be **exported**, not merely computed. buildkit reads it
from the environment. Missing the export does not fail anything — it silently
yields a different but still stable digest, so the check goes on passing locally
while disagreeing with every other caller. That bug existed in the first draft of
`verify-reproducible.sh` for about ten minutes and was caught only because the
digest did not match the one measured by hand.

**And buildkit's cache key does NOT include `SOURCE_DATE_EPOCH`.** A layer
cached from a build at a different epoch is reused as-is, and
`rewrite-timestamp` does not re-rewrite it — so the layer keeps the mtimes of
whenever it was first built. Any reproducibility check therefore needs
`--no-cache`, and `scripts/verify-reproducible.sh` now passes it in every mode.

Found on the v31.1-1 release, and it produced exactly the wrong kind of failure.
A laptop holding layers cached from earlier commits reported
`sha256:7eeef666…` while the runner, building fresh, published
`sha256:bbd7da4f…`. Everything else about the two images was identical — same
commit, same epoch, byte-identical labels, all 18 base layers matching — and
only the three layers this repo adds differed. Their tars carried mtimes from
"yesterday" and "this morning" rather than the commit epoch. With `--no-cache`
the laptop reproduced the published digest exactly, so **the build was
reproducible the whole time and the tool was wrong about it**.

The canonical mode was immune by accident: it pins the epoch to `0`, so its
cache is always self-consistent. Only `--release` and `--against` vary the
epoch, and neither runs in CI. An earlier "cached and `--no-cache` agree"
measurement had passed only because the cache happened to hold layers from the
same epoch at that moment — a measurement that was true when taken and not a
property of the system.

Worth being clear about why this was worse than a missing check. The README
tells consumers to run `make verify-repro-published`. On any machine that had
built this repo before, that command would have reported a mismatch **on a
perfectly good image** — a verification tool crying wolf about the exact claim
it exists to support. A check that fails loudly on correct input destroys more
trust than one that was never written.

That is the third time buildkit cache semantics have produced a wrong answer
here, after the attestation/image-store split and the `CACHED`-step problem in
`tests/test-threshold.sh`. **If a check involves buildkit and its result is
supposed to mean something, pass `--no-cache` and stop reasoning about it.**

**Exporters depend on your image store, in BOTH directions, and the two traps
point opposite ways.** This is the third time this class of difference has broken
something here, and the third time it passed locally first.

`rewrite-timestamp` conflicts with `unpack`:
`exporter option "rewrite-timestamp" conflicts with "unpack"`. The containerd
image store turns `unpack` on for `--load` and for `type=image`, so a dev box
with containerd rejects the flag and a runner with the classic store does not.
`make push` passes `unpack=false` explicitly so both behave the same.

The OCI exporter goes the other way:
`OCI exporter is not supported for the docker driver. Switch to a different
driver, or turn on the containerd image store`. It needs containerd **or** a
non-docker driver. A laptop with containerd has one; a runner has neither.

So "use an OCI layout export to avoid the unpack conflict" fixes the first trap
and walks straight into the second — which is exactly what happened, complete
with a comment in `verify-reproducible.sh` asserting the OCI path "works the
same on a laptop and on a runner". It does not. **The only thing that actually
works the same in both environments is a `docker-container` builder**, which is
what `release.yml` already used for attestations and what
`verify-reproducible.sh` now uses too. Reach for that first rather than
reasoning about which exporter happens to be portable.

`make build` keeps `--load` on the default builder and therefore does **not**
rewrite timestamps. That is fine: it exists to produce a local image for smoke,
verify-image and verify-contents, none of which care about digests.

**Buildkit itself is pinned by digest** (`BUILDKIT_IMAGE` in the Makefile,
asserted by `check-pins.sh` alongside the two base images). It is not a base the
image is built *from*, but it is the thing assembling the layers, so an unpinned
buildkit can move the expected digest with no change to this repository — CI
going red for a reason that is nobody's fault and that tells you nothing. The
pin is for determinism of the gate, not because the property is fragile:
measured 2026-09-22, buildkit v0.29.0 and v0.32.2 on different drivers produce
the identical image manifest digest, and pinning left
`reproducible-digest.txt` unchanged. `release.yml` reads the same value via
`make print-buildkit-image`, so the push and the reproducibility check cannot
drift onto different buildkits.

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
