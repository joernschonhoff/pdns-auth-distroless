CI_REGISTRY_IMAGE ?= registry.gitlab.com/joern_schonhoff/pdns-auth-distroless

# Read PowerDNS version from VERSION file
PDNS_AUTH_VERSION := $(shell cat VERSION)
# Validate version format (semantic versioning: X.Y.Z)
VALIDATE_VERSION := $(shell echo "$(PDNS_AUTH_VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' && echo "valid" || echo "invalid")

ifeq ($(VALIDATE_VERSION),invalid)
$(error Invalid VERSION format: "$(PDNS_AUTH_VERSION)". Expected semantic versioning (X.Y.Z))
endif

.PHONY: build-prod build-debug build test clean version help

help: ## Show this help message
	@echo "PowerDNS Authoritative Distroless - Build Targets"
	@echo "=================================================="
	@echo "Current PowerDNS version: $(PDNS_AUTH_VERSION)"
	@echo ""
	@grep -E '^[a-zA-Z]\S+:.*' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

version: ## Display current PowerDNS version
	@echo $(PDNS_AUTH_VERSION)

build-prod: ## Build production distroless image
docker buildx build \                                                               
        --platform linux/arm64 \
        --build-arg PDNS_AUTH_VERSION=$(PDNS_AUTH_VERSION) \
        --label org.opencontainers.image.created=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --tag "${CI_REGISTRY_IMAGE}:$(PDNS_AUTH_VERSION)" \
		--file Dockerfile .
	@echo "Built: pdns-auth-distroless:$(PDNS_AUTH_VERSION)"

build-debug: ## Build debug image with busybox shell
docker buildx build \                                                               
        --platform linux/arm64 \
        --build-arg PDNS_AUTH_VERSION=$(PDNS_AUTH_VERSION) \
        --label org.opencontainers.image.created=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --tag "${CI_REGISTRY_IMAGE}:$(PDNS_AUTH_VERSION)-debug" \
		--file Debug.Dockerfile .
	@echo "Built: pdns-auth-distroless:$(PDNS_AUTH_VERSION)-debug"

build: build-prod build-debug ## Build both production and debug images

test: ## Run basic test with docker compose
	docker compose up --build

test-examples: ## Test all example configurations
	@echo "Testing SQLite example..."
	cd examples/sqlite && docker compose up -d && docker compose down
	@echo "Testing MySQL example..."
	cd examples/mysql && docker compose up -d && docker compose down
	@echo "Testing PostgreSQL example..."
	cd examples/pgsql && docker compose up -d && docker compose down

verify: ## Verify built production image
	@echo "Verifying pdns-auth-distroless:$(PDNS_AUTH_VERSION)..."
	docker run --rm ${CI_REGISTRY_IMAGE}:$(PDNS_AUTH_VERSION) --version
	@echo "✓ Image verified successfully"

clean: ## Stop and remove all containers and volumes
	docker compose down -v
	cd examples/sqlite && docker compose down -v || true
	cd examples/mysql && docker compose down -v || true
	cd examples/pgsql && docker compose down -v || true

clean-images: ## Remove built images
	docker rmi ${CI_REGISTRY_IMAGE}:$(PDNS_AUTH_VERSION) || true
	docker rmi ${CI_REGISTRY_IMAGE}:$(PDNS_AUTH_VERSION)-debug || true
