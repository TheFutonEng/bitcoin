SHELL := /usr/bin/env bash

VERSION       ?= 31.1
TRIPLE        ?= x86_64-linux-gnu
PLATFORM      ?= linux/amd64
REGISTRY      ?= registry.example.com/bitcoin
IMAGE         ?= $(REGISTRY)/bitcoind
TAG           ?= $(VERSION)
# Pinned by digest (invariant 4). Keep in sync with the ARG in the Dockerfile.
RUNTIME_BASE  ?= gcr.io/distroless/cc-debian12@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
MIN_GOOD_SIGS ?= 6
# Seconds `make smoke` waits for the regtest node to finish loading.
SMOKE_TIMEOUT ?= 60

VCS_REF       := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
SOURCE_REPO   := $(shell git remote get-url origin 2>/dev/null || echo unknown)
# Pin timestamps to the commit so rebuilds of the same commit are comparable.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct 2>/dev/null || echo 0)
BUILD_DATE    := $(shell date -u -d @$(SOURCE_DATE_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 1970-01-01T00:00:00Z)

export SOURCE_DATE_EPOCH

.PHONY: help check-pins keyring fetch verify cross-check build smoke verify-image verify-contents verify-upstream digest sbom sign attest verify-sig clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s$$'\t'

fetch: ## Pull + verify a release into upstream/ (needs network)
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/fetch-release.sh $(VERSION) $(TRIPLE)

check-pins: ## Assert duplicated values agree across Dockerfile/Makefile/verify.sh
	scripts/check-pins.sh

keyring: ## Regenerate keys/trusted-keyring.gpg from keys/*.asc (the build verifies against it)
	scripts/build-keyring.sh

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
	  --provenance=true --sbom=true \
	  -t $(IMAGE):$(TAG) \
	  --load .

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

digest: ## Print the image digest — publish this, consumers pin it
	@docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):$(TAG) 2>/dev/null \
	  || echo "not pushed yet — run: docker push $(IMAGE):$(TAG)"

sbom: ## Generate an SBOM alongside the image
	syft $(IMAGE):$(TAG) -o spdx-json=sbom.spdx.json

sign: ## cosign sign the pushed image
	cosign sign --key $(COSIGN_KEY) $$(docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):$(TAG))

attest: ## Attach the provenance record + SBOM as attestations
	cosign attest --key $(COSIGN_KEY) \
	  --predicate provenance.json \
	  --type https://example.invalid/bitcoind-provenance/v1 \
	  $$(docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):$(TAG))
	cosign attest --key $(COSIGN_KEY) \
	  --predicate sbom.spdx.json --type spdxjson \
	  $$(docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):$(TAG))
	cosign attest --key $(COSIGN_KEY) \
	  --predicate contents-manifest.json \
	  --type https://example.invalid/bitcoind-contents/v1 \
	  $$(docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):$(TAG))

verify-sig: ## Verify the signature and attestations round-trip
	cosign verify --key $(COSIGN_KEY).pub $(IMAGE):$(TAG)
	cosign verify-attestation --key $(COSIGN_KEY).pub \
	  --type https://example.invalid/bitcoind-provenance/v1 $(IMAGE):$(TAG)

clean:
	rm -f provenance.json sbom.spdx.json contents-manifest.json
