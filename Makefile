SHELL := /usr/bin/env bash

VERSION       ?= 31.1
TRIPLE        ?= x86_64-linux-gnu
PLATFORM      ?= linux/amd64
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
TAG           ?= $(VERSION)
# Pinned by digest (invariant 4). Keep in sync with the ARG in the Dockerfile.
RUNTIME_BASE  ?= gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
MIN_GOOD_SIGS ?= 6
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

VCS_REF       := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
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

.PHONY: help check-pins keyring fetch fetch-tarball verify cross-check build push smoke sign attest digest-ref verify-image verify-contents verify-upstream digest sbom sign attest verify-sig clean

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
	  --build-arg TARGET_TRIPLE=$(TRIPLE) \
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
push: ## Build and push with full provenance + SBOM attestations
	@echo "pushing $(IMAGE):$(TAG)"
	docker buildx build \
	  --platform $(PLATFORM) \
	  --network=none \
	  --build-arg BITCOIN_VERSION=$(VERSION) \
	  --build-arg TARGET_TRIPLE=$(TRIPLE) \
	  --build-arg RUNTIME_BASE=$(RUNTIME_BASE) \
	  --build-arg MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) \
	  --build-arg SOURCE_REPO=$(SOURCE_REPO) \
	  --build-arg VCS_REF=$(VCS_REF) \
	  --build-arg BUILD_DATE=$(BUILD_DATE) \
	  --provenance=mode=max --sbom=true \
	  -t $(IMAGE):$(TAG) \
	  --push .

smoke: ## Prove the runtime base can actually run the binaries
	@echo "--- bitcoind -version ---"
	docker run --rm $(IMAGE):$(TAG) -version
	@echo "--- bitcoin-cli -version ---"
	docker run --rm --entrypoint /usr/local/bin/bitcoin-cli $(IMAGE):$(TAG) -version
	@echo "--- regtest boot ---"
	@# The old form backgrounded `docker run`, slept, and killed the client PID,
	@# so it always exited 0 and could not fail. This runs the node with a
	@# deadline and ASSERTS it reached "init message: Done loading". /data is used
	@# because it is the declared VOLUME; /tmp is not guaranteed to exist in a
	@# distroless image. The tmpfs is NOT incidental: /data does not exist in the
	@# base, so a plain VOLUME comes up root-owned and bitcoind as 65532 cannot
	@# write it — which is the consumer caveat in the README, and this target
	@# proved it the first time it actually asserted.
	@set -e; \
	log=$$(mktemp); cid=smoke-$$$$; \
	docker run --rm --name $$cid \
	  --tmpfs /data:uid=65532,gid=65532,mode=0700 \
	  --entrypoint /usr/local/bin/bitcoind \
	  $(IMAGE):$(TAG) -regtest -datadir=/data -printtoconsole -connect=0 -listen=0 \
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
	scripts/verify-image.sh $(IMAGE):$(TAG) $(VERSION) $(TRIPLE)

verify-contents: ## Prove EVERY file in the image is accounted for, not just the binaries
	scripts/verify-contents.sh $(IMAGE):$(TAG) $(VERSION) $(TRIPLE)

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

sbom: ## Generate an SBOM from the pushed image
	syft $(IMAGE):$(TAG) -o spdx-json=sbom.spdx.json

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
