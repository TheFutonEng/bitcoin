SHELL := /usr/bin/env bash

# The UPSTREAM Bitcoin Core version. This selects the release tarball and the
# signed sums; it is not the image's version. See REVISION.
VERSION       ?= 31.1
# The image revision for that Bitcoin version — the Debian
# `upstream_version-debian_revision` model. Same binaries, different packaging.
#
# Bump this whenever the published image changes for a reason that is NOT a new
# Bitcoin release: a base image bump, a Dockerfile change, a change to which
# binaries ship. Reset it to 1 when VERSION changes. Docs- or CI-only changes
# publish nothing, so they do not bump it. A rebuild of an unchanged commit
# produces an identical image (`make verify-repro`), so there is never anything
# to publish for that either.
#
# Starts at 1, not 0, which is what Debian does and what `31.1-1` should mean:
# the first packaging of 31.1. Keep in sync with ARG IMAGE_REVISION in the
# Dockerfile — check-pins.sh asserts it, the same way it does MIN_GOOD_SIGS.
REVISION      ?= 2
# PLATFORM selects the architecture; TRIPLE follows from it and is not meant to
# be set on its own. The Dockerfile makes the same mapping from TARGETARCH — it
# has to, because one multi-platform build cannot take a per-platform build arg
# — and a TRIPLE that disagreed with PLATFORM would have the host scripts verify
# one tarball while the build shipped another. Keep this table and the one in
# the Dockerfile's digest-check step identical.
PLATFORM      ?= linux/amd64
TRIPLE_linux/amd64 := x86_64-linux-gnu
TRIPLE_linux/arm64 := aarch64-linux-gnu
ifeq ($(origin TRIPLE),command line)
$(error TRIPLE is derived from PLATFORM — pass PLATFORM=linux/arm64 instead)
endif
TRIPLE        := $(or $(TRIPLE_$(PLATFORM)),$(error no tarball triple for PLATFORM=$(PLATFORM)))
# The platforms a release publishes, together, as one OCI index. Also the set
# the reproducibility claim covers: verify-reproducible.sh --write reads this
# line, and check-pins.sh asserts the CI and release matrices list the same
# architectures. Every entry must have a triple above.
PLATFORMS     ?= linux/amd64 linux/arm64
$(foreach p,$(PLATFORMS),$(if $(TRIPLE_$(p)),,$(error PLATFORMS lists $(p), which has no tarball triple)))
# Each platform's attestation predicates live apart, because each describes a
# different image: its own tarball, its own files, its own SBOM. sign-image.sh
# attaches predicates/<os>-<arch>/ to that platform's manifest digest.
PREDICATES    := predicates/$(subst /,-,$(PLATFORM))
comma := ,
space := $(subst ,, )
# GHCR: lives with the repo, so the published image is the archive, and CI
# authenticates with the built-in GITHUB_TOKEN rather than a stored credential.
REGISTRY      ?= ghcr.io/thefutoneng
# `bitcoin`, not `bitcoind`. Every other published Bitcoin Core container is
# called "bitcoin" — bitcoin/bitcoin, bitcoinknots/bitcoin — and the consumable
# artifact this repo releases should match that convention rather than invent a
# name. The predicate types below deliberately stay `bitcoind-*`: they identify a
# payload describing the daemon, not the image, and changing a predicate type
# after publishing breaks verification for everything already signed.
IMAGE         ?= $(REGISTRY)/bitcoin
# The published tag is VERSION-REVISION, never the bare Bitcoin version. A bare
# `:31.1` would be ambiguous the moment the image changes without the binaries
# changing, which is precisely what REVISION exists to express.
TAG           ?= $(VERSION)-$(REVISION)
# Pinned by digest (invariant 4). Keep in sync with the ARG in the Dockerfile.
RUNTIME_BASE  ?= gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
MIN_GOOD_SIGS ?= 6
# The buildkit used for reproducibility checks and for the release push, pinned
# by digest for the same reason as the base images (invariant 5). It is a build
# input: an unpinned buildkit could change how layers are assembled and move the
# expected digest with no change to this repository, turning CI red for a reason
# that is nobody's fault and telling you nothing.
#
# The pin is for determinism of the GATE, not because the property is fragile —
# the same image manifest digest was measured under buildkit v0.29.0 and v0.32.2
# on different drivers. Bumping this is a reviewed commit, and it is expected to
# leave reproducible-digest.txt unchanged; if it does not, that is worth
# understanding before merging.
BUILDKIT_IMAGE ?= moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8
# Seconds `make smoke` waits for the regtest node to finish loading.
SMOKE_TIMEOUT ?= 60

# Attestation predicate types. These are identifiers, not URLs to fetch; they
# only need to be stable and unambiguous. spdxjson is cosign's built-in type.
PRED_PROVENANCE ?= https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-provenance/v1
PRED_CONTENTS   ?= https://github.com/TheFutonEng/bitcoin/predicate/bitcoind-contents/v1
export PRED_PROVENANCE PRED_CONTENTS

# Keyless verification must name the identity it expects, or it would accept a
# signature from anyone Sigstore will issue a certificate to. This is the release
# workflow running on a tag.
RELEASE_IDENTITY ?= ^https://github\.com/TheFutonEng/bitcoin/\.github/workflows/release\.yml@refs/tags/
COSIGN_ISSUER    ?= https://token.actions.githubusercontent.com

# Empty by default, on purpose. `verify-signatures.sh` checks a mode only when
# its config is present, so a local run with just a public key checks the
# key-pair mode and does not fail on a keyless signature that was never made.
# The release workflow sets COSIGN_IDENTITY=$(RELEASE_IDENTITY) to check both.
COSIGN_IDENTITY  ?=

# Length is pinned. `git rev-parse --short` auto-sizes the abbreviation from the
# repository's object count, so the same commit can abbreviate to 7 characters in
# one clone and 8 in another as the repo grows — a different LABEL, and therefore
# a different image digest, for identical inputs. Same class of problem as the
# SOURCE_REPO normalisation below.
VCS_REF       := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
# Normalised to a browsable https URL. `git remote get-url` returns the SSH form
# on a dev box and https under actions/checkout, which would put two different
# values in org.opencontainers.image.source for the same commit — and therefore
# produce two different image digests, defeating the reproducible-rebuild goal.
SOURCE_REPO   := $(shell git remote get-url origin 2>/dev/null \
                   | sed -e 's#^git@\([^:]*\):#https://\1/#' -e 's#\.git$$##' \
                   || echo unknown)
# Pin timestamps to the commit so rebuilds of the same commit are comparable.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct 2>/dev/null || echo 0)
BUILD_DATE    := $(shell date -u -d @$(SOURCE_DATE_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 1970-01-01T00:00:00Z)

export SOURCE_DATE_EPOCH

.PHONY: help check-pins keyring fetch fetch-tarball verify cross-check build push smoke sign attest digest-ref verify-image verify-contents verify-upstream digest sbom sign attest verify-sig test test-threshold print-buildkit-image print-image-ref print-version print-revision print-triple print-platforms platform-ref verify-published repro-digest repro-digest-write verify-repro verify-repro-published clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s$$'\t'

fetch: ## Pull + verify a release into upstream/ (needs network)
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/fetch-release.sh $(VERSION) $(TRIPLE)

check-pins: ## Assert duplicated values agree across Dockerfile/Makefile/verify.sh
	scripts/check-pins.sh

keyring: ## Regenerate keys/trusted-keyring.gpg from keys/*.asc (the build verifies against it)
	scripts/build-keyring.sh

# Download ONLY the tarball, leaving the committed SHA256SUMS and .asc alone.
# This is the rebuilder's path and what CI uses: it proves the sums already in
# git admit the bytes upstream is serving. `make fetch` re-downloads the sums
# too, which is right when vendoring a new version but wrong as a check, since
# it would verify freshly-fetched sums against themselves.
fetch-tarball: ## Download just the release tarball (sums must already be committed)
	@test -f upstream/SHA256SUMS || { echo "upstream/SHA256SUMS missing — run make fetch" >&2; exit 1; }
	curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
	  --output upstream/bitcoin-$(VERSION)-$(TRIPLE).tar.gz \
	  https://bitcoincore.org/bin/bitcoin-core-$(VERSION)/bitcoin-$(VERSION)-$(TRIPLE).tar.gz

verify: check-pins ## Re-verify what is already in upstream/
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/verify.sh $(VERSION) $(TRIPLE)

cross-check: ## Second opinion on the signature threshold from Core's verify.py (needs network)
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/cross-check-verify-py.sh $(VERSION) $(TRIPLE)

build: verify ## Build the image (hermetic — no network in the build)
	docker buildx build \
	  --platform $(PLATFORM) \
	  --network=none \
	  --build-arg BITCOIN_VERSION=$(VERSION) \
	  --build-arg IMAGE_REVISION=$(REVISION) \
	  --build-arg RUNTIME_BASE=$(RUNTIME_BASE) \
	  --build-arg MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) \
	  --build-arg SOURCE_REPO=$(SOURCE_REPO) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg BUILD_DATE=$(BUILD_DATE) \
	  --provenance=false --sbom=false \
	  -t $(IMAGE):$(TAG) \
	  --load .

# Attestations are REGISTRY artifacts: buildkit emits them as separate manifests
# in an OCI index beside the image. A `--load` into the classic docker image
# store has nowhere to put them, and buildx fails outright:
#
#   ERROR: Attestation is not supported for the docker driver.
#
# This passed locally and failed in CI because this machine has the containerd
# image store enabled, which does support them. `make build` produces a local
# image for smoke/verify-image/verify-contents and needs no attestations, so it
# asks for none. They belong on the push, where they can actually be stored.
#
# mode=max records build args and materials, not just the build definition.
# Not a dependency of `build`, and `build` is not a dependency of this: it would
# silently build twice. Run the verification chain first —
#   make build smoke verify-image verify-contents push
#
# `--push` is spelled out as `--output type=image,push=true` so the two
# reproducibility options can ride along:
#
#   rewrite-timestamp=true  rewrites layer file mtimes to SOURCE_DATE_EPOCH.
#     Without it every file we add carries the wall-clock time of the build and
#     the published image differs on every rebuild of the same commit. This is
#     what makes `make verify-repro-published` able to pass at all.
#   unpack=false            the containerd image store turns unpack on by
#     default and buildkit refuses rewrite-timestamp alongside it. Runners using
#     the classic store never unpack here, so the flag is a no-op there and the
#     two environments stop differing — the failure mode that has bitten this
#     repo's build tooling twice.
#
# Every platform in PLATFORMS, in ONE build, so the result is one index. The
# arm64 image is cross-built on an amd64 runner with no emulation: the verifier
# stage runs on the build platform and the runtime stage only copies files. The
# release proves the published arm64 image has exactly the files of the one
# that booted natively in its preflight job — see release.yml.
push: ## Build and push every platform in PLATFORMS as one index, with attestations
	@echo "pushing $(IMAGE):$(TAG) for $(PLATFORMS)"
	docker buildx build \
	  --platform $(subst $(space),$(comma),$(strip $(PLATFORMS))) \
	  --network=none \
	  --build-arg BITCOIN_VERSION=$(VERSION) \
	  --build-arg IMAGE_REVISION=$(REVISION) \
	  --build-arg RUNTIME_BASE=$(RUNTIME_BASE) \
	  --build-arg MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) \
	  --build-arg SOURCE_REPO=$(SOURCE_REPO) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg BUILD_DATE=$(BUILD_DATE) \
	  --provenance=mode=max --sbom=true \
	  -t $(IMAGE):$(TAG) \
	  --output type=image,push=true,rewrite-timestamp=true,unpack=false .

smoke: ## Prove the runtime base can actually run the binaries
	@echo "--- bitcoind -version ---"
	docker run --rm $(IMAGE):$(TAG) -version
	@echo "--- bitcoin-cli -version ---"
	docker run --rm --entrypoint /usr/local/bin/bitcoin-cli $(IMAGE):$(TAG) -version
	@echo "--- regtest boot ---"
	@# The old form backgrounded `docker run`, slept, and killed the client PID,
	@# so it always exited 0 and could not fail. This runs the node with a
	@# deadline and ASSERTS it reached "init message: Done loading".
	@#
	@# No --entrypoint override and no -datadir/-printtoconsole here, deliberately.
	@# --entrypoint DISCARDS the image's own arguments, so the old form tested a
	@# bitcoind invocation this image never actually performs. Passing only the
	@# extra flags exercises what a consumer gets: ENTRYPOINT supplies the datadir
	@# and console logging, and user arguments append to them.
	@#
	@# The tmpfs is now for speed and isolation rather than necessity — /data ships
	@# in the image owned by 65532, so a plain run works. tests/test-config.sh is
	@# what proves that; this target should stay a fast liveness check.
	@set -e; \
	log=$$(mktemp); cid=smoke-$$$$; \
	docker run --rm --name $$cid \
	  --tmpfs /data:uid=65532,gid=65532,mode=0700 \
	  $(IMAGE):$(TAG) -regtest -connect=0 -listen=0 \
	  -dbcache=4 -maxmempool=5 > $$log 2>&1 & \
	ok=0; \
	for i in $$(seq 1 $(SMOKE_TIMEOUT)); do \
	  if grep -q 'init message: Done loading' $$log 2>/dev/null; then ok=1; break; fi; \
	  if [ $$i -ge 3 ] && ! docker ps -q -f name=$$cid | grep -q .; then \
	    sleep 1; break; \
	  fi; \
	  sleep 1; \
	done; \
	docker stop -t 1 $$cid >/dev/null 2>&1 || true; wait 2>/dev/null || true; \
	if [ $$ok -eq 1 ]; then \
	  echo "regtest boot: OK (node reached 'Done loading' in $${i}s)"; rm -f $$log; \
	else \
	  echo "regtest boot: FAILED — node never finished loading" >&2; \
	  cat $$log >&2; rm -f $$log; exit 1; \
	fi

verify-image: ## Prove the image's binaries are the verified upstream bytes (works on any image)
	PLATFORM=$(PLATFORM) scripts/verify-image.sh $(IMAGE):$(TAG) $(VERSION) $(TRIPLE)

verify-contents: ## Prove EVERY file in the image is accounted for, not just the binaries
	PLATFORM=$(PLATFORM) scripts/verify-contents.sh $(IMAGE):$(TAG) $(VERSION) $(TRIPLE)

# Reproducibility. Note carefully what is and is not claimed: the IMAGE MANIFEST
# is reproducible, the published OCI INDEX is not, because the attestations it
# wraps carry per-build timestamps and random ids. Read the header of
# scripts/verify-reproducible.sh before repeating either claim.
print-buildkit-image: ## Print the pinned buildkit image (used by release.yml)
	@echo "$(BUILDKIT_IMAGE)"

# release.yml compares these against the git tag it was launched from.
print-image-ref: ## Print IMAGE:TAG (used by tests/)
	@echo "$(IMAGE):$(TAG)"

print-version: ## Print the upstream Bitcoin version
	@echo "$(VERSION)"

print-revision: ## Print the image revision for that Bitcoin version
	@echo "$(REVISION)"

# For CI, which needs the tarball name to cache it. Asking make keeps the
# workflow from becoming another copy of the arch table check-pins polices.
print-triple: ## Print the tarball triple for PLATFORM
	@echo "$(TRIPLE)"

print-platforms: ## Print the platforms a release publishes
	@echo "$(PLATFORMS)"

repro-digest: ## Print the image manifest digest THIS commit builds
	PLATFORM=$(PLATFORM) scripts/verify-reproducible.sh --release

repro-digest-write: ## Update reproducible-digest.txt (a reviewed commit)
	PLATFORM=$(PLATFORM) scripts/verify-reproducible.sh --write

verify-repro: ## Assert this tree still builds the committed canonical digest
	PLATFORM=$(PLATFORM) scripts/verify-reproducible.sh

verify-repro-published: ## Prove a PUBLISHED image is bit-for-bit this commit
	PLATFORM=$(PLATFORM) scripts/verify-reproducible.sh --against $(IMAGE):$(TAG)

# PLATFORM's image inside the PUSHED index, as IMAGE@<its manifest digest>. Read
# from the registry, never the local store. Accepts a variant suffix, since an
# index may say linux/arm64/v8 where PLATFORM says linux/arm64.
platform-ref: ## Print IMAGE@digest of PLATFORM's image in the pushed index
	@set -euo pipefail; \
	d="$$(scripts/list-platforms.sh $(IMAGE):$(TAG) \
	      | awk -v p='$(PLATFORM)' '$$1 == p || index($$1, p "/") == 1 { print $$2 }')"; \
	if [ "$$(printf '%s' "$$d" | grep -c .)" != 1 ]; then \
	  echo "expected exactly one $(PLATFORM) image in $(IMAGE):$(TAG), got: '$$d'" >&2; exit 1; \
	fi; \
	echo "$(IMAGE)@$$d"

# Verifies ONE platform of the published index and writes its predicates.
#
# By DIGEST, and that is the point. Before 2026-09-25 the release re-verified
# `$(IMAGE):$(TAG)`, which `make build` had already put in the local store —
# so `docker create` used the local copy and the step never read the registry.
# A digest ref cannot be satisfied by a different local image: either the bytes
# are identical, or docker pulls. The explicit pull makes that unconditional.
#
# The predicates it writes are the ones sign-image.sh attaches, so an image is
# only ever attested with evidence produced from its own digest.
verify-published: ## Verify PLATFORM's image in the pushed index by digest; write its predicates
	@set -euo pipefail; \
	ref="$$($(MAKE) -s platform-ref)"; \
	echo ">> $(PLATFORM): $$ref"; \
	docker pull -q --platform $(PLATFORM) "$$ref" >/dev/null; \
	PLATFORM=$(PLATFORM) scripts/verify-image.sh "$$ref" $(VERSION) $(TRIPLE); \
	PLATFORM=$(PLATFORM) MANIFEST=$(PREDICATES)/contents-manifest.json \
	  scripts/verify-contents.sh "$$ref" $(VERSION) $(TRIPLE); \
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) PROVENANCE_OUT=$(PREDICATES)/provenance.json \
	  scripts/verify.sh $(VERSION) $(TRIPLE); \
	syft --platform $(PLATFORM) "$$ref" -o spdx-json=$(PREDICATES)/sbom.spdx.json; \
	echo "predicates: $(PREDICATES)/"

# The only test in the repo that can fail for a security reason rather than an
# operational one. It needs docker and the tarball, so it sits with the rest of
# the chain rather than with check-pins.
#
# `test` is the aggregate: as the negative-test suite grows, add targets here and
# CI picks them up without another workflow edit.
test: test-threshold test-config ## Run every test

test-threshold: ## Prove BOTH threshold implementations agree and fail closed
	tests/test-threshold.sh $(VERSION) $(TRIPLE)

# Needs a built image, unlike test-threshold which builds what it needs.
test-config: ## Prove config and the datadir reach the container, and the example is not stale
	tests/test-config.sh $(IMAGE):$(TAG)

# bitcoin/bitcoin unpacks the release tarball into /opt and puts it on PATH,
# rather than installing into /usr/local/bin as we do. Verified against
# willcl-ark/bitcoin-core-docker 31.1/Dockerfile, which does:
#   tar -xzf ... -C /opt
#   ENV PATH=/opt/bitcoin-<version>/bin:$PATH
verify-upstream: ## Same check, run against the third-party bitcoin/bitcoin image
	BIN_PATH=/opt/bitcoin-$(VERSION)/bin \
	  scripts/verify-image.sh bitcoin/bitcoin:$(VERSION) $(VERSION) $(TRIPLE)

digest-ref: ## Print the full pinnable reference: IMAGE@sha256:...
	@echo "$(IMAGE)@$$(docker buildx imagetools inspect $(IMAGE):$(TAG) --format '{{.Manifest.Digest}}')"

digest: ## Print the pushed image digest — publish this, consumers pin it
	@docker buildx imagetools inspect $(IMAGE):$(TAG) --format '{{.Manifest.Digest}}' 2>/dev/null \
	  || echo "not pushed yet — run: make push"

sbom: ## Generate PLATFORM's SBOM from the pushed index (verify-published does this too)
	@mkdir -p $(PREDICATES)
	syft --platform $(PLATFORM) "$$($(MAKE) -s platform-ref)" -o spdx-json=$(PREDICATES)/sbom.spdx.json

# `sign` and `attest` are the same operation — cosign attaches the signature and
# the three predicates to one digest — so they are one script and one target.
# `attest` is kept as an alias because the documented workflow named it.
sign: ## Sign the pushed image and attach all three attestations
	scripts/sign-image.sh $(IMAGE):$(TAG)

attest: sign ## Alias for sign — cosign attaches signature and predicates together

verify-sig: ## Prove the signature AND all three attestations round-trip
	COSIGN_IDENTITY='$(COSIGN_IDENTITY)' COSIGN_ISSUER='$(COSIGN_ISSUER)' \
	  scripts/verify-signatures.sh $(IMAGE):$(TAG)

clean:
	rm -f provenance.json sbom.spdx.json contents-manifest.json
	rm -rf predicates/
