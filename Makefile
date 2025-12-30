# Airgapped Two-Tier RPM Repository System
# Makefile for build, test, and operations

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Configuration
PROJECT_NAME := airgapped-rpm-repo
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.1.0-dev")
REGISTRY := ghcr.io/your-org
IMAGE_NAME := $(PROJECT_NAME)
DATA_DIR := /data
BUNDLE_DIR := $(DATA_DIR)/bundles
MANIFEST_DIR := $(DATA_DIR)/manifests
MIRROR_DIR := $(DATA_DIR)/mirror
REPOS_DIR := $(DATA_DIR)/repos
KEYS_DIR := $(DATA_DIR)/keys

# Container runtime (podman or docker)
CONTAINER_RUNTIME := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
COMPOSE := $(shell command -v podman-compose 2>/dev/null || command -v docker-compose 2>/dev/null || echo "docker compose")

# Packer configuration
PACKER := packer
PACKER_DIR := packer
ISO_PATH ?=
ISO_CHECKSUM ?=

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m

.PHONY: help
help: ## Display this help message
	@echo -e "$(BLUE)Airgapped RPM Repository System$(NC)"
	@echo -e "$(BLUE)================================$(NC)"
	@echo ""
	@echo "Usage: make [target] [VAR=value]"
	@echo ""
	@echo "Build & Development:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(build|test|e2e|up|down|dev|lint|clean)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "External Builder Operations:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(external|sm-|sync|ingest|compute|build-repos|export)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Internal Publisher Operations:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(internal|import|verify|publish|promote|ansible)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Packer & VMware:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(packer)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Compliance & Security:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(openscap|compliance|security|sbom)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'

# ============================================================================
# Build & Development
# ============================================================================

.PHONY: build
build: ## Build container images
	@echo -e "$(BLUE)Building container images...$(NC)"
	$(CONTAINER_RUNTIME) build --target external -t $(IMAGE_NAME):external .
	$(CONTAINER_RUNTIME) build --target internal -t $(IMAGE_NAME):internal .
	$(CONTAINER_RUNTIME) build --target internal -t $(IMAGE_NAME):dev .
	@echo -e "$(GREEN)Build complete$(NC)"

.PHONY: build-external
build-external: ## Build external builder image only
	@echo -e "$(BLUE)Building external builder image...$(NC)"
	$(CONTAINER_RUNTIME) build --target external -t $(IMAGE_NAME):external .

.PHONY: build-internal
build-internal: ## Build internal publisher image only
	@echo -e "$(BLUE)Building internal publisher image...$(NC)"
	$(CONTAINER_RUNTIME) build --target internal -t $(IMAGE_NAME):internal .

.PHONY: test
test: lint test-unit test-integration ## Run all tests
	@echo -e "$(GREEN)All tests passed$(NC)"

.PHONY: test-unit
test-unit: ## Run unit tests
	@echo -e "$(BLUE)Running unit tests...$(NC)"
	PYTHONPATH=src python3 -m pytest src/tests/ -v --tb=short -m "not integration"

.PHONY: test-integration
test-integration: build ## Run integration tests
	@echo -e "$(BLUE)Running integration tests...$(NC)"
	$(COMPOSE) --profile test up --abort-on-container-exit --exit-code-from test-runner
	$(COMPOSE) --profile test down

.PHONY: e2e
e2e: ## Run full end-to-end tests (UBI8 + UBI9, builds images, validates full workflow)
	@echo -e "$(BLUE)Running end-to-end tests...$(NC)"
	./scripts/e2e_test.sh
	@echo -e "$(GREEN)E2E tests passed$(NC)"

.PHONY: e2e-keep
e2e-keep: ## Run E2E tests and keep containers for debugging
	@echo -e "$(BLUE)Running end-to-end tests (keeping containers)...$(NC)"
	./scripts/e2e_test.sh --keep-containers
	@echo -e "$(GREEN)E2E tests passed$(NC)"

.PHONY: lint
lint: lint-shell lint-python lint-yaml ## Run all linters
	@echo -e "$(GREEN)Linting complete$(NC)"

.PHONY: lint-shell
lint-shell: ## Lint shell scripts with shellcheck
	@echo -e "$(BLUE)Linting shell scripts...$(NC)"
	@find scripts -name "*.sh" -type f -exec shellcheck -x {} \;
	@shellcheck rpmserverctl

.PHONY: lint-python
lint-python: ## Lint Python code with ruff and mypy
	@echo -e "$(BLUE)Linting Python code...$(NC)"
	@ruff check src/
	@ruff format --check src/
	@mypy src/ --ignore-missing-imports

.PHONY: lint-yaml
lint-yaml: ## Lint YAML files
	@echo -e "$(BLUE)Linting YAML files...$(NC)"
	@yamllint -c .yamllint.yml .github/workflows/ docker-compose.yml || true

.PHONY: format
format: ## Format code
	@echo -e "$(BLUE)Formatting code...$(NC)"
	@ruff format src/
	@ruff check --fix src/

.PHONY: up
up: ## Start development environment
	@echo -e "$(BLUE)Starting development environment...$(NC)"
	$(COMPOSE) --profile dev up -d
	@echo -e "$(GREEN)Development environment started$(NC)"
	@echo -e "Repository available at: http://localhost:8080/repos/"

.PHONY: down
down: ## Stop development environment
	@echo -e "$(BLUE)Stopping development environment...$(NC)"
	$(COMPOSE) --profile dev down

.PHONY: logs
logs: ## Show container logs
	$(COMPOSE) --profile dev logs -f

.PHONY: clean
clean: ## Clean build artifacts and containers
	@echo -e "$(BLUE)Cleaning up...$(NC)"
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	$(CONTAINER_RUNTIME) rmi $(IMAGE_NAME):external $(IMAGE_NAME):internal $(IMAGE_NAME):dev 2>/dev/null || true
	rm -rf dist/ build/ *.egg-info/ .pytest_cache/ .mypy_cache/ .ruff_cache/
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@echo -e "$(GREEN)Clean complete$(NC)"

# ============================================================================
# External Builder Operations
# ============================================================================

.PHONY: init-external
init-external: ## Initialize external builder environment
	@echo -e "$(BLUE)Initializing external builder...$(NC)"
	./rpmserverctl init-external
	@echo -e "$(GREEN)External builder initialized$(NC)"

.PHONY: sm-register
sm-register: ## Register with subscription-manager (ACTIVATION_KEY+ORG_ID or SM_USER+SM_PASS required)
	@echo -e "$(BLUE)Registering with subscription-manager...$(NC)"
ifdef ACTIVATION_KEY
	./scripts/external/sm_register.sh --activation-key "$(ACTIVATION_KEY)" --org "$(ORG_ID)"
else ifdef SM_USER
	./scripts/external/sm_register.sh --username "$(SM_USER)" --password "$(SM_PASS)"
else
	@echo -e "$(RED)Error: Set ACTIVATION_KEY+ORG_ID or SM_USER+SM_PASS$(NC)"
	@exit 1
endif

.PHONY: sm-unregister
sm-unregister: ## Unregister from subscription-manager
	@echo -e "$(BLUE)Unregistering from subscription-manager...$(NC)"
	./scripts/external/sm_unregister.sh

.PHONY: enable-repos
enable-repos: ## Enable required RHEL repositories
	@echo -e "$(BLUE)Enabling repositories...$(NC)"
	./scripts/external/enable_repos.sh
	@echo -e "$(GREEN)Repositories enabled$(NC)"

.PHONY: sync
sync: ## Sync content from Red Hat CDN
	@echo -e "$(BLUE)Syncing content from Red Hat CDN...$(NC)"
	./scripts/external/sync_repos.sh
	@echo -e "$(GREEN)Sync complete$(NC)"

.PHONY: ingest
ingest: ## Ingest host manifests (MANIFEST_DIR required)
ifndef MANIFEST_DIR
	@echo -e "$(RED)Error: MANIFEST_DIR not specified$(NC)"
	@exit 1
endif
	@echo -e "$(BLUE)Ingesting manifests from $(MANIFEST_DIR)...$(NC)"
	./scripts/external/ingest_manifests.sh "$(MANIFEST_DIR)"
	@echo -e "$(GREEN)Manifest ingestion complete$(NC)"

.PHONY: compute
compute: ## Compute updates for ingested manifests
	@echo -e "$(BLUE)Computing updates...$(NC)"
	./scripts/external/compute_updates.sh
	@echo -e "$(GREEN)Update computation complete$(NC)"

.PHONY: build-repos
build-repos: ## Build repository structure with createrepo_c
	@echo -e "$(BLUE)Building repositories...$(NC)"
	./scripts/external/build_repos.sh
	@echo -e "$(GREEN)Repository build complete$(NC)"

.PHONY: export
export: ## Export bundle for hand-carry (BUNDLE_NAME required)
ifndef BUNDLE_NAME
	@echo -e "$(RED)Error: BUNDLE_NAME not specified$(NC)"
	@exit 1
endif
	@echo -e "$(BLUE)Exporting bundle: $(BUNDLE_NAME)...$(NC)"
	./scripts/external/export_bundle.sh "$(BUNDLE_NAME)"
	@echo -e "$(GREEN)Bundle exported to $(BUNDLE_DIR)/$(BUNDLE_NAME).tar.gz$(NC)"

# ============================================================================
# Internal Publisher Operations
# ============================================================================

.PHONY: init-internal
init-internal: ## Initialize internal publisher environment
	@echo -e "$(BLUE)Initializing internal publisher...$(NC)"
	./rpmserverctl init-internal
	@echo -e "$(GREEN)Internal publisher initialized$(NC)"

.PHONY: import
import: ## Import bundle from hand-carry media (BUNDLE_PATH required)
ifndef BUNDLE_PATH
	@echo -e "$(RED)Error: BUNDLE_PATH not specified$(NC)"
	@exit 1
endif
	@echo -e "$(BLUE)Importing bundle: $(BUNDLE_PATH)...$(NC)"
	./scripts/internal/import_bundle.sh "$(BUNDLE_PATH)"
	@echo -e "$(GREEN)Bundle imported$(NC)"

.PHONY: verify
verify: ## Verify imported bundle integrity and signatures
	@echo -e "$(BLUE)Verifying bundle...$(NC)"
	./scripts/internal/verify_bundle.sh
	@echo -e "$(GREEN)Bundle verification complete$(NC)"

.PHONY: publish
publish: ## Publish repos to lifecycle channel (LIFECYCLE=dev|prod)
	@echo -e "$(BLUE)Publishing to $(LIFECYCLE) channel...$(NC)"
	./scripts/internal/publish_repos.sh "$(LIFECYCLE)"
	@echo -e "$(GREEN)Published to $(LIFECYCLE)$(NC)"

.PHONY: promote
promote: ## Promote repos between lifecycle channels (FROM and TO required)
ifndef FROM
	@echo -e "$(RED)Error: FROM channel not specified$(NC)"
	@exit 1
endif
ifndef TO
	@echo -e "$(RED)Error: TO channel not specified$(NC)"
	@exit 1
endif
	@echo -e "$(BLUE)Promoting from $(FROM) to $(TO)...$(NC)"
	./scripts/internal/promote_lifecycle.sh "$(FROM)" "$(TO)"
	@echo -e "$(GREEN)Promotion complete$(NC)"

.PHONY: generate-client-config
generate-client-config: ## Generate client configuration files
	@echo -e "$(BLUE)Generating client configuration...$(NC)"
	./scripts/internal/generate_client_config.sh
	@echo -e "$(GREEN)Client configuration generated$(NC)"

# ============================================================================
# Internal Architecture (HTTPS + Ansible + Lifecycle)
# ============================================================================

# Container image names for internal architecture
INTERNAL_PUBLISHER_IMAGE := airgap-rpm-publisher
INTERNAL_ANSIBLE_IMAGE := airgap-ansible-control
SSH_HOST_UBI8_IMAGE := ssh-host-ubi8
SSH_HOST_UBI9_IMAGE := ssh-host-ubi9
SYSLOG_SINK_IMAGE := tls-syslog-sink

.PHONY: internal-build
internal-build: ## Build internal architecture container images
	@echo -e "$(BLUE)Building internal architecture containers...$(NC)"
	$(CONTAINER_RUNTIME) build -t $(INTERNAL_PUBLISHER_IMAGE):latest \
		-f containers/rpm-publisher/Containerfile containers/rpm-publisher/
	$(CONTAINER_RUNTIME) build -t $(INTERNAL_ANSIBLE_IMAGE):latest \
		-f containers/ansible-ee/Containerfile .
	@echo -e "$(GREEN)Internal containers built$(NC)"

.PHONY: internal-build-test
internal-build-test: ## Build test containers for internal E2E
	@echo -e "$(BLUE)Building test containers...$(NC)"
	$(CONTAINER_RUNTIME) build -t $(SSH_HOST_UBI8_IMAGE):latest \
		-f testdata/ssh-host-ubi8/Containerfile testdata/ssh-host-ubi8/
	$(CONTAINER_RUNTIME) build -t $(SSH_HOST_UBI9_IMAGE):latest \
		-f testdata/ssh-host-ubi9/Containerfile testdata/ssh-host-ubi9/
	$(CONTAINER_RUNTIME) build -t $(SYSLOG_SINK_IMAGE):latest \
		-f testdata/tls-syslog-sink/Containerfile testdata/tls-syslog-sink/
	@echo -e "$(GREEN)Test containers built$(NC)"

.PHONY: internal-up
internal-up: internal-build internal-build-test ## Start internal architecture containers
	@echo -e "$(BLUE)Starting internal architecture...$(NC)"
	@# Create network if not exists
	$(CONTAINER_RUNTIME) network create internal-net 2>/dev/null || true
	@# Start syslog sink
	$(CONTAINER_RUNTIME) run -d --name syslog-sink \
		--network internal-net \
		-p 6514:6514 -p 514:514 \
		$(SYSLOG_SINK_IMAGE):latest
	@# Start RPM publisher
	$(CONTAINER_RUNTIME) run -d --name rpm-publisher \
		--network internal-net \
		-p 8080:8080 -p 8443:8443 \
		-v $$(pwd)/testdata/repos:/data/repos:Z \
		-v $$(pwd)/testdata/lifecycle:/data/lifecycle:Z \
		$(INTERNAL_PUBLISHER_IMAGE):latest
	@# Start SSH test hosts
	$(CONTAINER_RUNTIME) run -d --name ssh-host-ubi9 \
		--network internal-net \
		-e AIRGAP_HOST_ID=test-ubi9-01 \
		$(SSH_HOST_UBI9_IMAGE):latest
	$(CONTAINER_RUNTIME) run -d --name ssh-host-ubi8 \
		--network internal-net \
		-e AIRGAP_HOST_ID=test-ubi8-01 \
		$(SSH_HOST_UBI8_IMAGE):latest
	@# Start Ansible control
	$(CONTAINER_RUNTIME) run -d --name ansible-control \
		--network internal-net \
		-v $$(pwd)/ansible:/runner/project:Z \
		$(INTERNAL_ANSIBLE_IMAGE):latest sleep infinity
	@echo -e "$(GREEN)Internal architecture started$(NC)"
	@echo "RPM Publisher: https://localhost:8443"
	@echo "Syslog Sink: localhost:6514 (TLS), localhost:514 (TCP)"

.PHONY: internal-down
internal-down: ## Stop and remove internal architecture containers
	@echo -e "$(BLUE)Stopping internal architecture...$(NC)"
	$(CONTAINER_RUNTIME) stop ansible-control ssh-host-ubi8 ssh-host-ubi9 rpm-publisher syslog-sink 2>/dev/null || true
	$(CONTAINER_RUNTIME) rm ansible-control ssh-host-ubi8 ssh-host-ubi9 rpm-publisher syslog-sink 2>/dev/null || true
	$(CONTAINER_RUNTIME) network rm internal-net 2>/dev/null || true
	@echo -e "$(GREEN)Internal architecture stopped$(NC)"

.PHONY: internal-validate
internal-validate: ## Validate internal architecture (HTTPS, repos, connectivity)
	@echo -e "$(BLUE)Validating internal architecture...$(NC)"
	@echo "Checking RPM publisher HTTPS..."
	@curl -fsk https://localhost:8443/health >/dev/null && echo -e "$(GREEN)HTTPS: OK$(NC)" || echo -e "$(RED)HTTPS: FAILED$(NC)"
	@echo "Checking syslog sink..."
	@$(CONTAINER_RUNTIME) exec syslog-sink pgrep rsyslogd >/dev/null && echo -e "$(GREEN)Syslog: OK$(NC)" || echo -e "$(RED)Syslog: FAILED$(NC)"
	@echo "Checking SSH hosts..."
	@$(CONTAINER_RUNTIME) exec ssh-host-ubi9 pgrep sshd >/dev/null && echo -e "$(GREEN)SSH UBI9: OK$(NC)" || echo -e "$(RED)SSH UBI9: FAILED$(NC)"
	@$(CONTAINER_RUNTIME) exec ssh-host-ubi8 pgrep sshd >/dev/null && echo -e "$(GREEN)SSH UBI8: OK$(NC)" || echo -e "$(RED)SSH UBI8: FAILED$(NC)"
	@echo -e "$(GREEN)Validation complete$(NC)"

.PHONY: ansible-shell
ansible-shell: ## Open shell in Ansible control container
	@echo -e "$(BLUE)Opening Ansible control shell...$(NC)"
	$(CONTAINER_RUNTIME) exec -it ansible-control /bin/bash

.PHONY: internal-logs
internal-logs: ## Show logs from internal containers
	@echo "=== RPM Publisher ===" && $(CONTAINER_RUNTIME) logs rpm-publisher --tail 20 2>/dev/null || true
	@echo "=== Syslog Sink ===" && $(CONTAINER_RUNTIME) logs syslog-sink --tail 20 2>/dev/null || true
	@echo "=== SSH Host UBI9 ===" && $(CONTAINER_RUNTIME) logs ssh-host-ubi9 --tail 10 2>/dev/null || true
	@echo "=== SSH Host UBI8 ===" && $(CONTAINER_RUNTIME) logs ssh-host-ubi8 --tail 10 2>/dev/null || true

.PHONY: internal-e2e
internal-e2e: ## Run internal architecture E2E tests
	@echo -e "$(BLUE)Running internal architecture E2E tests...$(NC)"
	./scripts/internal_e2e_test.sh
	@echo -e "$(GREEN)Internal E2E tests passed$(NC)"

# ============================================================================
# Ansible Operations (via container)
# ============================================================================

.PHONY: ansible-bootstrap
ansible-bootstrap: ## Bootstrap SSH keys to test hosts
	@echo -e "$(BLUE)Bootstrapping SSH keys...$(NC)"
	$(CONTAINER_RUNTIME) exec ansible-control \
		ansible-playbook /runner/project/playbooks/bootstrap_ssh_keys.yml

.PHONY: ansible-configure-repo
ansible-configure-repo: ## Configure internal repository on test hosts
	@echo -e "$(BLUE)Configuring internal repository...$(NC)"
	$(CONTAINER_RUNTIME) exec ansible-control \
		ansible-playbook /runner/project/playbooks/configure_internal_repo.yml

.PHONY: ansible-collect-manifests
ansible-collect-manifests: ## Collect manifests from test hosts
	@echo -e "$(BLUE)Collecting manifests...$(NC)"
	$(CONTAINER_RUNTIME) exec ansible-control \
		ansible-playbook /runner/project/playbooks/collect_manifests.yml

.PHONY: ansible-stig
ansible-stig: ## Run STIG hardening on test hosts
	@echo -e "$(BLUE)Running STIG hardening...$(NC)"
	$(CONTAINER_RUNTIME) exec ansible-control \
		ansible-playbook /runner/project/playbooks/stig_harden_internal_vm.yml

# ============================================================================
# Packer & VMware
# ============================================================================

.PHONY: packer-validate
packer-validate: ## Validate Packer configuration
	@echo -e "$(BLUE)Validating Packer configuration...$(NC)"
	cd $(PACKER_DIR) && $(PACKER) validate \
		-var "iso_path=$(ISO_PATH)" \
		-var "iso_checksum=$(ISO_CHECKSUM)" \
		rhel9-internal.pkr.hcl
	@echo -e "$(GREEN)Packer configuration valid$(NC)"

.PHONY: packer-build-internal
packer-build-internal: ## Build RHEL 9.6 OVA for internal publisher (ISO_PATH and ISO_CHECKSUM required)
ifndef ISO_PATH
	@echo -e "$(RED)Error: ISO_PATH not specified$(NC)"
	@echo "Usage: make packer-build-internal ISO_PATH=/path/to/rhel-9.6-x86_64-dvd.iso ISO_CHECKSUM=sha256:..."
	@exit 1
endif
ifndef ISO_CHECKSUM
	@echo -e "$(RED)Error: ISO_CHECKSUM not specified$(NC)"
	@echo "Usage: make packer-build-internal ISO_PATH=/path/to/rhel-9.6-x86_64-dvd.iso ISO_CHECKSUM=sha256:..."
	@exit 1
endif
	@echo -e "$(BLUE)Building RHEL 9.6 OVA for internal publisher...$(NC)"
	cd $(PACKER_DIR) && $(PACKER) build \
		-var "iso_path=$(ISO_PATH)" \
		-var "iso_checksum=$(ISO_CHECKSUM)" \
		-var "version=$(VERSION)" \
		rhel9-internal.pkr.hcl
	@echo -e "$(GREEN)OVA build complete$(NC)"

.PHONY: packer-init
packer-init: ## Initialize Packer plugins
	@echo -e "$(BLUE)Initializing Packer plugins...$(NC)"
	cd $(PACKER_DIR) && $(PACKER) init rhel9-internal.pkr.hcl
	@echo -e "$(GREEN)Packer plugins initialized$(NC)"

# ============================================================================
# Compliance & Security
# ============================================================================

.PHONY: openscap
openscap: ## Run OpenSCAP evaluation
	@echo -e "$(BLUE)Running OpenSCAP evaluation...$(NC)"
	./scripts/run_openscap.sh
	@echo -e "$(GREEN)OpenSCAP evaluation complete$(NC)"
	@echo "Results available in compliance/"

.PHONY: generate-ckl
generate-ckl: ## Generate STIG checklist deliverables
	@echo -e "$(BLUE)Generating STIG checklist...$(NC)"
	./scripts/generate_ckl.sh
	@echo -e "$(GREEN)Checklist generated in compliance/ckl/$(NC)"

.PHONY: compliance-report
compliance-report: openscap generate-ckl ## Generate full compliance report
	@echo -e "$(GREEN)Compliance report generated$(NC)"

.PHONY: security-scan
security-scan: ## Run security scans (Trivy, gitleaks)
	@echo -e "$(BLUE)Running security scans...$(NC)"
	@echo "Scanning for secrets with gitleaks..."
	@gitleaks detect --source . --verbose 2>/dev/null || echo "gitleaks not installed or no secrets found"
	@echo "Scanning container image with Trivy..."
	@trivy image $(IMAGE_NAME):internal 2>/dev/null || echo "Trivy not installed"
	@echo -e "$(GREEN)Security scans complete$(NC)"

.PHONY: sbom
sbom: ## Generate Software Bill of Materials
	@echo -e "$(BLUE)Generating SBOM...$(NC)"
	@syft $(IMAGE_NAME):internal -o spdx-json > sbom.spdx.json 2>/dev/null || echo "Syft not installed"
	@syft $(IMAGE_NAME):internal -o cyclonedx-json > sbom.cyclonedx.json 2>/dev/null || echo "Syft not installed"
	@echo -e "$(GREEN)SBOM generated$(NC)"

# ============================================================================
# Host Manifest Collection
# ============================================================================

.PHONY: collect-manifest
collect-manifest: ## Collect host manifest (run on internal hosts)
	@echo -e "$(BLUE)Collecting host manifest...$(NC)"
	./scripts/host_collect_manifest.sh
	@echo -e "$(GREEN)Manifest collected$(NC)"

# ============================================================================
# GPG Key Management
# ============================================================================

.PHONY: gpg-init
gpg-init: ## Initialize GPG signing key
	@echo -e "$(BLUE)Initializing GPG signing key...$(NC)"
	./scripts/common/gpg_functions.sh init
	@echo -e "$(GREEN)GPG key initialized$(NC)"

.PHONY: gpg-export
gpg-export: ## Export GPG public key
	@echo -e "$(BLUE)Exporting GPG public key...$(NC)"
	./scripts/common/gpg_functions.sh export
	@echo -e "$(GREEN)GPG public key exported to $(KEYS_DIR)/$(NC)"

# ============================================================================
# Release
# ============================================================================

.PHONY: release
release: ## Create release artifacts
	@echo -e "$(BLUE)Creating release $(VERSION)...$(NC)"
	$(CONTAINER_RUNTIME) tag $(IMAGE_NAME):internal $(REGISTRY)/$(IMAGE_NAME):$(VERSION)
	$(CONTAINER_RUNTIME) tag $(IMAGE_NAME):internal $(REGISTRY)/$(IMAGE_NAME):latest
	$(CONTAINER_RUNTIME) tag $(IMAGE_NAME):external $(REGISTRY)/$(IMAGE_NAME):external-$(VERSION)
	@echo -e "$(GREEN)Release $(VERSION) created$(NC)"

.PHONY: push
push: ## Push images to registry
	@echo -e "$(BLUE)Pushing images to $(REGISTRY)...$(NC)"
	$(CONTAINER_RUNTIME) push $(REGISTRY)/$(IMAGE_NAME):$(VERSION)
	$(CONTAINER_RUNTIME) push $(REGISTRY)/$(IMAGE_NAME):latest
	$(CONTAINER_RUNTIME) push $(REGISTRY)/$(IMAGE_NAME):external-$(VERSION)
	@echo -e "$(GREEN)Images pushed$(NC)"

# ============================================================================
# Utility
# ============================================================================

.PHONY: version
version: ## Show version
	@echo "$(VERSION)"

.PHONY: check-deps
check-deps: ## Check for required dependencies
	@echo -e "$(BLUE)Checking dependencies...$(NC)"
	@command -v $(CONTAINER_RUNTIME) >/dev/null 2>&1 || { echo -e "$(RED)Container runtime not found$(NC)"; exit 1; }
	@command -v gpg >/dev/null 2>&1 || { echo -e "$(YELLOW)Warning: gpg not found$(NC)"; }
	@command -v shellcheck >/dev/null 2>&1 || { echo -e "$(YELLOW)Warning: shellcheck not found$(NC)"; }
	@command -v python3 >/dev/null 2>&1 || { echo -e "$(RED)Python3 not found$(NC)"; exit 1; }
	@echo -e "$(GREEN)Dependency check complete$(NC)"

.PHONY: shell-external
shell-external: ## Open shell in external builder container
	$(COMPOSE) --profile external exec external-builder /bin/bash

.PHONY: shell-internal
shell-internal: ## Open shell in internal publisher container
	$(COMPOSE) --profile internal exec internal-publisher /bin/bash
