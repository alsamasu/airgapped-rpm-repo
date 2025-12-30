# Makefile - Airgapped RPM Repository System
#
# This Makefile provides targets for deploying and managing the
# airgapped RPM repository infrastructure.
#
# Configuration: config/spec.yaml
#
# Usage:
#   make help                  - Show available targets
#   make vsphere-discover      - Discover vSphere environment
#   make spec-init             - Initialize spec.yaml from discovery
#   make e2e                   - Run full E2E test suite
#   make build-ovas            - Build OVAs from running VMs
#   make guide-validate        - Validate operator guide

.PHONY: help validate-spec servers-deploy servers-destroy servers-report \
        ansible-onboard ansible-bootstrap manifests patch compliance \
        render-inventory generate-ks-iso upload-isos lint test clean \
        vsphere-discover spec-init e2e build-ovas guide-validate

# Configuration
SPEC_FILE ?= config/spec.yaml
INVENTORY ?= ansible/inventories/generated.yml
POWERCLI_DIR = automation/powercli
ANSIBLE_DIR = ansible
SCRIPTS_DIR = automation/scripts
ARTIFACTS_DIR = automation/artifacts
OUTPUT_DIR = output

# Colors for terminal output
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

#------------------------------------------------------------------------------
# Help
#------------------------------------------------------------------------------

help:
	@echo ""
	@echo "$(CYAN)Airgapped RPM Repository System$(NC)"
	@echo "=================================="
	@echo ""
	@echo "$(GREEN)Discovery & Initialization:$(NC)"
	@echo "  vsphere-discover   Discover vSphere environment and generate defaults"
	@echo "  spec-init          Initialize spec.yaml from discovered defaults"
	@echo ""
	@echo "$(GREEN)Configuration:$(NC)"
	@echo "  validate-spec      Validate spec.yaml configuration"
	@echo "  render-inventory   Generate Ansible inventory from spec.yaml"
	@echo ""
	@echo "$(GREEN)VMware Deployment:$(NC)"
	@echo "  servers-deploy     Deploy external/internal VMs (full workflow)"
	@echo "  servers-destroy    Destroy all deployed VMs"
	@echo "  servers-report     Report VM status and DHCP IPs"
	@echo "  generate-ks-iso    Generate kickstart ISOs"
	@echo "  upload-isos        Upload ISOs to VMware datastore"
	@echo ""
	@echo "$(GREEN)Testing & Validation:$(NC)"
	@echo "  e2e                Run full E2E test suite"
	@echo "  guide-validate     Validate operator guide against implementation"
	@echo "  test               Run basic tests"
	@echo ""
	@echo "$(GREEN)OVA Building:$(NC)"
	@echo "  build-ovas         Build OVAs from running VMs (after E2E passes)"
	@echo ""
	@echo "$(GREEN)Ansible Operations:$(NC)"
	@echo "  ansible-onboard    Bootstrap SSH keys and configure hosts"
	@echo "  ansible-bootstrap  Bootstrap SSH keys only (password -> key auth)"
	@echo "  manifests          Collect package manifests from hosts"
	@echo "  patch              Apply monthly security patches"
	@echo "  compliance         Run STIG hardening and compliance checks"
	@echo ""
	@echo "$(GREEN)Development:$(NC)"
	@echo "  lint               Lint PowerShell, YAML, and shell scripts"
	@echo "  clean              Remove generated files"
	@echo ""
	@echo "$(YELLOW)Configuration file:$(NC) $(SPEC_FILE)"
	@echo ""

#------------------------------------------------------------------------------
# Discovery & Initialization
#------------------------------------------------------------------------------

vsphere-discover:
	@echo "$(CYAN)Discovering vSphere environment...$(NC)"
	@mkdir -p $(ARTIFACTS_DIR)
	@pwsh -File $(POWERCLI_DIR)/discover-vsphere-defaults.ps1 \
		-OutputDir $(ARTIFACTS_DIR)
	@echo ""
	@echo "$(GREEN)Discovery complete!$(NC)"
	@echo "  JSON output:  $(ARTIFACTS_DIR)/vsphere-defaults.json"
	@echo "  Spec template: $(ARTIFACTS_DIR)/spec.detected.yaml"
	@echo ""
	@echo "Next: Run 'make spec-init' to initialize config/spec.yaml"

spec-init: vsphere-discover
	@echo "$(CYAN)Initializing spec.yaml from discovered defaults...$(NC)"
	@if [ -f config/spec.yaml ]; then \
		echo "$(YELLOW)WARNING: config/spec.yaml already exists$(NC)"; \
		echo "Backing up to config/spec.yaml.bak"; \
		cp config/spec.yaml config/spec.yaml.bak; \
	fi
	@cp $(ARTIFACTS_DIR)/spec.detected.yaml config/spec.yaml
	@echo "$(GREEN)spec.yaml initialized!$(NC)"
	@echo ""
	@echo "Review and customize: config/spec.yaml"
	@echo "Then run: make validate-spec"

#------------------------------------------------------------------------------
# Configuration Validation
#------------------------------------------------------------------------------

validate-spec:
	@echo "$(CYAN)Validating spec.yaml...$(NC)"
	@chmod +x automation/scripts/validate-spec.sh
	@./automation/scripts/validate-spec.sh $(SPEC_FILE)

render-inventory: validate-spec
	@echo "$(CYAN)Generating Ansible inventory from spec.yaml...$(NC)"
	@python3 automation/scripts/render-inventory.py \
		--spec $(SPEC_FILE) \
		--output $(INVENTORY)
	@echo "$(GREEN)Inventory written to: $(INVENTORY)$(NC)"

#------------------------------------------------------------------------------
# VMware Deployment
#------------------------------------------------------------------------------

generate-ks-iso: validate-spec
	@echo "$(CYAN)Generating kickstart ISOs...$(NC)"
	@mkdir -p $(OUTPUT_DIR)/ks-isos
	@pwsh -File $(POWERCLI_DIR)/generate-ks-iso.ps1 \
		-SpecPath $(SPEC_FILE) \
		-OutputDir $(OUTPUT_DIR)/ks-isos

upload-isos: generate-ks-iso
	@echo "$(CYAN)Uploading ISOs to VMware datastore...$(NC)"
	@pwsh -File $(POWERCLI_DIR)/upload-isos.ps1 \
		-SpecPath $(SPEC_FILE) \
		-KsIsoDir $(OUTPUT_DIR)/ks-isos

servers-deploy: validate-spec render-inventory
	@echo "$(CYAN)Deploying RPM servers...$(NC)"
	@pwsh -File $(POWERCLI_DIR)/deploy-rpm-servers.ps1 \
		-SpecPath $(SPEC_FILE)
	@echo ""
	@echo "$(GREEN)Deployment initiated. Run 'make servers-report' to check status.$(NC)"

servers-destroy:
	@echo "$(RED)WARNING: This will destroy all deployed VMs!$(NC)"
	@pwsh -File $(POWERCLI_DIR)/destroy-rpm-servers.ps1 \
		-SpecPath $(SPEC_FILE)

servers-report:
	@echo "$(CYAN)Reporting VM status...$(NC)"
	@pwsh -File $(POWERCLI_DIR)/wait-for-dhcp-and-report.ps1 \
		-SpecPath $(SPEC_FILE) \
		-WaitForIP:$$false

servers-wait:
	@echo "$(CYAN)Waiting for installation to complete...$(NC)"
	@pwsh -File $(POWERCLI_DIR)/wait-for-install-complete.ps1 \
		-SpecPath $(SPEC_FILE)

#------------------------------------------------------------------------------
# E2E Testing
#------------------------------------------------------------------------------

e2e: validate-spec
	@echo "$(CYAN)Running E2E test suite...$(NC)"
	@mkdir -p $(ARTIFACTS_DIR)/e2e
	@chmod +x $(SCRIPTS_DIR)/run-e2e-tests.sh
	@$(SCRIPTS_DIR)/run-e2e-tests.sh \
		--spec $(SPEC_FILE) \
		--output-dir $(ARTIFACTS_DIR)/e2e
	@echo ""
	@echo "$(GREEN)E2E tests complete!$(NC)"
	@echo "  Report: $(ARTIFACTS_DIR)/e2e/report.md"
	@echo "  JSON:   $(ARTIFACTS_DIR)/e2e/report.json"

guide-validate:
	@echo "$(CYAN)Validating operator guide...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/validate-operator-guide.sh
	@$(SCRIPTS_DIR)/validate-operator-guide.sh \
		--guide docs/operator_guide_automated.md \
		--spec $(SPEC_FILE)
	@echo "$(GREEN)Guide validation complete!$(NC)"

#------------------------------------------------------------------------------
# OVA Building
#------------------------------------------------------------------------------

build-ovas: validate-spec
	@echo "$(CYAN)Building OVAs from running VMs...$(NC)"
	@mkdir -p $(ARTIFACTS_DIR)/ovas
	@pwsh -File $(POWERCLI_DIR)/build-ovas.ps1 \
		-SpecPath $(SPEC_FILE) \
		-OutputDir $(ARTIFACTS_DIR)/ovas
	@echo ""
	@echo "$(GREEN)OVA build complete!$(NC)"
	@echo "  Output: $(ARTIFACTS_DIR)/ovas/"
	@ls -la $(ARTIFACTS_DIR)/ovas/*.ova 2>/dev/null || true

#------------------------------------------------------------------------------
# Ansible Operations
#------------------------------------------------------------------------------

# Full onboarding: SSH keys + repo config + syslog
ansible-onboard: render-inventory
	@echo "$(CYAN)Onboarding managed hosts...$(NC)"
	@echo "Step 1: Bootstrapping SSH keys (password auth)..."
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/bootstrap_ssh_keys.yml \
		--ask-pass
	@echo ""
	@echo "Step 2: Configuring repository access..."
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/onboard_hosts.yml
	@echo ""
	@echo "$(GREEN)Onboarding complete!$(NC)"

# Bootstrap SSH keys only
ansible-bootstrap: render-inventory
	@echo "$(CYAN)Bootstrapping SSH keys...$(NC)"
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/bootstrap_ssh_keys.yml \
		--ask-pass

# Collect manifests for hand-carry
manifests: render-inventory
	@echo "$(CYAN)Collecting package manifests...$(NC)"
	@mkdir -p $(ANSIBLE_DIR)/artifacts/manifests
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/collect_manifests.yml
	@echo ""
	@echo "$(GREEN)Manifests saved to: $(ANSIBLE_DIR)/artifacts/manifests/$(NC)"
	@echo "Copy this directory to removable media for hand-carry to external server."

# Monthly security patching
patch: render-inventory
	@echo "$(CYAN)Running monthly security patches...$(NC)"
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/patch_monthly_security.yml
	@echo ""
	@echo "$(GREEN)Patching complete!$(NC)"

# STIG hardening and compliance
compliance: render-inventory
	@echo "$(CYAN)Running STIG hardening and compliance checks...$(NC)"
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/stig_harden_internal_vm.yml
	@echo ""
	@echo "$(GREEN)Compliance checks complete!$(NC)"

# Replace TLS certificate
replace-tls-cert:
	@echo "$(CYAN)Replacing TLS certificate...$(NC)"
	@if [ -z "$(CERT_PATH)" ] || [ -z "$(KEY_PATH)" ]; then \
		echo "$(RED)Error: CERT_PATH and KEY_PATH required$(NC)"; \
		echo "Usage: make replace-tls-cert CERT_PATH=/path/to/cert KEY_PATH=/path/to/key"; \
		exit 1; \
	fi
	cd $(ANSIBLE_DIR) && ansible-playbook \
		-i inventories/generated.yml \
		playbooks/replace_repo_tls_cert.yml \
		-e "cert_path=$(CERT_PATH)" \
		-e "key_path=$(KEY_PATH)" \
		$(if $(CA_CHAIN),-e "ca_chain_path=$(CA_CHAIN)",)

#------------------------------------------------------------------------------
# External Server Operations (run on external server)
#------------------------------------------------------------------------------

# These targets are run on the external RPM server

sm-register:
	@echo "$(CYAN)Registering with Red Hat Subscription Manager...$(NC)"
	@./scripts/external/sm_register.sh

enable-repos:
	@echo "$(CYAN)Enabling required repositories...$(NC)"
	@./scripts/external/enable_repos.sh

sync:
	@echo "$(CYAN)Synchronizing repositories...$(NC)"
	@./scripts/external/sync_repos.sh

build-repos:
	@echo "$(CYAN)Building repository metadata...$(NC)"
	@./scripts/external/build_repos.sh

export:
	@if [ -z "$(BUNDLE_NAME)" ]; then \
		echo "$(RED)Error: BUNDLE_NAME required$(NC)"; \
		echo "Usage: make export BUNDLE_NAME=patch-202501"; \
		exit 1; \
	fi
	@echo "$(CYAN)Creating export bundle: $(BUNDLE_NAME)$(NC)"
	@./scripts/external/export_bundle.sh "$(BUNDLE_NAME)"

#------------------------------------------------------------------------------
# Internal Server Operations (run on internal server)
#------------------------------------------------------------------------------

import:
	@if [ -z "$(BUNDLE_PATH)" ]; then \
		echo "$(RED)Error: BUNDLE_PATH required$(NC)"; \
		echo "Usage: make import BUNDLE_PATH=/data/import/bundle.tar.gz"; \
		exit 1; \
	fi
	@echo "$(CYAN)Importing bundle: $(BUNDLE_PATH)$(NC)"
	@./scripts/internal/import_bundle.sh "$(BUNDLE_PATH)"

verify:
	@echo "$(CYAN)Verifying imported bundle...$(NC)"
	@./scripts/internal/verify_bundle.sh

publish:
	@echo "$(CYAN)Publishing repositories...$(NC)"
	@./scripts/internal/publish_repos.sh $(LIFECYCLE)

promote:
	@if [ -z "$(FROM)" ] || [ -z "$(TO)" ]; then \
		echo "$(RED)Error: FROM and TO required$(NC)"; \
		echo "Usage: make promote FROM=testing TO=stable"; \
		exit 1; \
	fi
	@echo "$(CYAN)Promoting from $(FROM) to $(TO)...$(NC)"
	@./scripts/internal/promote_lifecycle.sh "$(FROM)" "$(TO)"

#------------------------------------------------------------------------------
# Development and CI
#------------------------------------------------------------------------------

lint:
	@echo "$(CYAN)Running linters...$(NC)"
	@echo "Checking YAML files..."
	@find . -name "*.yml" -o -name "*.yaml" | xargs -I {} python3 -c "import yaml; yaml.safe_load(open('{}'))" 2>&1 || true
	@echo ""
	@echo "Checking shell scripts..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		find . -name "*.sh" -exec shellcheck {} \; ; \
	else \
		echo "$(YELLOW)shellcheck not installed, skipping$(NC)"; \
	fi
	@echo ""
	@echo "Checking PowerShell scripts..."
	@if command -v pwsh >/dev/null 2>&1; then \
		find . -name "*.ps1" -exec pwsh -Command "Invoke-ScriptAnalyzer -Path '{}' -Severity Error" \; 2>/dev/null || true; \
	else \
		echo "$(YELLOW)PowerShell not installed, skipping$(NC)"; \
	fi
	@echo ""
	@echo "$(GREEN)Lint complete$(NC)"

test:
	@echo "$(CYAN)Running tests...$(NC)"
	@echo "Validating spec.yaml template..."
	@python3 -c "import yaml; yaml.safe_load(open('config/spec.yaml'))"
	@echo "$(GREEN)[OK]$(NC) spec.yaml is valid YAML"
	@echo ""
	@echo "Testing inventory renderer..."
	@python3 automation/scripts/render-inventory.py --spec config/spec.yaml --stdout > /dev/null
	@echo "$(GREEN)[OK]$(NC) Inventory renders successfully"
	@echo ""
	@echo "$(GREEN)All tests passed$(NC)"

clean:
	@echo "$(CYAN)Cleaning generated files...$(NC)"
	rm -rf $(OUTPUT_DIR)
	rm -f $(ANSIBLE_DIR)/inventories/generated.yml
	rm -rf $(ANSIBLE_DIR)/artifacts/manifests/*
	rm -rf $(ARTIFACTS_DIR)/e2e/*
	rm -rf $(ARTIFACTS_DIR)/ovas/*
	@echo "$(GREEN)Clean complete$(NC)"

#------------------------------------------------------------------------------
# Quick Start Workflow
#------------------------------------------------------------------------------

# Full deployment workflow
deploy-all: validate-spec generate-ks-iso upload-isos servers-deploy
	@echo ""
	@echo "$(GREEN)=========================================$(NC)"
	@echo "$(GREEN)Full deployment workflow complete!$(NC)"
	@echo "$(GREEN)=========================================$(NC)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. make servers-wait    - Wait for installation"
	@echo "  2. make servers-report  - Get IP addresses"
	@echo "  3. Update inventory with IPs"
	@echo "  4. make ansible-onboard - Configure hosts"

# Full E2E workflow (deploy + test + build OVAs)
e2e-full: deploy-all servers-wait e2e build-ovas
	@echo ""
	@echo "$(GREEN)=========================================$(NC)"
	@echo "$(GREEN)Full E2E workflow complete!$(NC)"
	@echo "$(GREEN)=========================================$(NC)"
	@echo ""
	@echo "Artifacts:"
	@echo "  E2E Report: $(ARTIFACTS_DIR)/e2e/report.md"
	@echo "  OVAs:       $(ARTIFACTS_DIR)/ovas/"

# Convenience aliases
deploy: servers-deploy
destroy: servers-destroy
status: servers-report
onboard: ansible-onboard
