SHELL := /usr/bin/env bash

VERSION       ?= 31.1
TRIPLE        ?= x86_64-linux-gnu
PLATFORM      ?= linux/amd64
REGISTRY      ?= registry.example.com/bitcoin
IMAGE         ?= $(REGISTRY)/bitcoind
TAG           ?= $(VERSION)
RUNTIME_BASE  ?= gcr.io/distroless/cc-debian12:nonroot
MIN_GOOD_SIGS ?= 6

VCS_REF       := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
SOURCE_REPO   := $(shell git remote get-url origin 2>/dev/null || echo unknown)
# Pin timestamps to the commit so rebuilds of the same commit are comparable.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct 2>/dev/null || echo 0)
BUILD_DATE    := $(shell date -u -d @$(SOURCE_DATE_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 1970-01-01T00:00:00Z)

export SOURCE_DATE_EPOCH

.PHONY: help fetch verify build smoke verify-image verify-upstream digest sbom sign attest verify-sig clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s$$'\t'

fetch: ## Pull + verify a release into vendor/ (needs network)
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/fetch-release.sh $(VERSION) $(TRIPLE)

verify: ## Re-verify what is already in vendor/
	MIN_GOOD_SIGS=$(MIN_GOOD_SIGS) scripts/verify.sh $(VERSION) $(TRIPLE)

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
	docker run --rm --entrypoint /usr/local/bin/bitcoind $(IMAGE):$(TAG) \
	  -regtest -datadir=/tmp -printtoconsole -connect=0 -listen=0 & \
	  pid=$$!; sleep 8; kill $$pid 2>/dev/null || true

verify-image: ## Prove the image's binaries are the verified upstream bytes (works on any image)
	scripts/verify-image.sh $(IMAGE):$(TAG) $(VERSION) $(TRIPLE)

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

verify-sig: ## Verify the signature and attestations round-trip
	cosign verify --key $(COSIGN_KEY).pub $(IMAGE):$(TAG)
	cosign verify-attestation --key $(COSIGN_KEY).pub \
	  --type https://example.invalid/bitcoind-provenance/v1 $(IMAGE):$(TAG)

clean:
	rm -f provenance.json sbom.spdx.json
