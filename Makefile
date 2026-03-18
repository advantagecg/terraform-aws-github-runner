IMAGES_DIR := images
VALID_COMPONENTS := ubuntu-general ubuntu-terraform
AWS_PROFILE ?= acg-main
SUBNET_ID ?=

# Build -var flags for packer (only include subnet_id if set)
PACKER_VARS := $(if $(SUBNET_ID),-var subnet_id=$(SUBNET_ID),)

# Require COMPONENT for packer targets
define require_component
	@if [ -z "$(COMPONENT)" ]; then \
		echo "Error: COMPONENT is required. Usage: make $@ COMPONENT=<image>"; \
		echo "Valid components: $(VALID_COMPONENTS)"; \
		exit 1; \
	fi
	@if [ ! -d "$(IMAGES_DIR)/$(COMPONENT)" ]; then \
		echo "Error: '$(IMAGES_DIR)/$(COMPONENT)' does not exist."; \
		echo "Valid components: $(VALID_COMPONENTS)"; \
		exit 1; \
	fi
endef

# Runner log groups
REGION ?= us-east-1
MINUTES ?= 10
LOG_GROUPS := webhook scale-up-general scale-up-terraform scale-down-general scale-down-terraform runner-startup-general runner-startup-terraform runner-general runner-terraform

# Map short names to full log group paths
log-group-webhook := /aws/lambda/github-runner-webhook
log-group-scale-up-general := /aws/lambda/github-runner-ubuntu-general-scale-up
log-group-scale-up-terraform := /aws/lambda/github-runner-ubuntu-terraform-scale-up
log-group-scale-down-general := /aws/lambda/github-runner-ubuntu-general-scale-down
log-group-scale-down-terraform := /aws/lambda/github-runner-ubuntu-terraform-scale-down
log-group-runner-startup-general := /github-self-hosted-runners/github-runner-ubuntu-general/runner-startup
log-group-runner-startup-terraform := /github-self-hosted-runners/github-runner-ubuntu-terraform/runner-startup
log-group-runner-general := /github-self-hosted-runners/github-runner-ubuntu-general/runner
log-group-runner-terraform := /github-self-hosted-runners/github-runner-ubuntu-terraform/runner

.PHONY: help packer-init packer-fmt packer-fmt-check packer-validate packer-build packer-all logs logs-list

.DEFAULT_GOAL := help

help:
	@echo "Packer image builder"
	@echo ""
	@echo "Usage:"
	@echo "  make <target> COMPONENT=<image> [AWS_PROFILE=<profile>]"
	@echo ""
	@echo "Components:"
	@echo "  ubuntu-general    General CI/CD runner (Docker, AWS CLI, Node.js, Python)"
	@echo "  ubuntu-terraform  Terraform runner (ubuntu-general + Terraform toolchain)"
	@echo ""
	@echo "Options:"
	@echo "  AWS_PROFILE  AWS credentials profile to use (default: acg-main)"
	@echo "  SUBNET_ID    Subnet for the Packer builder instance (required if no default VPC)"
	@echo ""
	@echo "Targets:"
	@echo "  packer-init        Download required Packer plugins"
	@echo "  packer-fmt         Format HCL files in-place"
	@echo "  packer-fmt-check   Check HCL formatting (non-destructive, for CI)"
	@echo "  packer-validate    Validate configuration (equivalent to plan)"
	@echo "  packer-build       Build and publish the AMI (equivalent to apply)"
	@echo "  packer-all         Run full pipeline: init -> fmt-check -> validate -> build"
	@echo ""
	@echo "Examples:"
	@echo "  make packer-init     COMPONENT=ubuntu-general"
	@echo "  make packer-validate COMPONENT=ubuntu-terraform"
	@echo "  make packer-build    COMPONENT=ubuntu-general"
	@echo "  make packer-build    COMPONENT=ubuntu-general    AWS_PROFILE=my-profile"
	@echo "  make packer-all      COMPONENT=ubuntu-terraform"

packer-init:
	$(call require_component)
	cd $(IMAGES_DIR)/$(COMPONENT) && packer init .

packer-fmt:
	$(call require_component)
	cd $(IMAGES_DIR)/$(COMPONENT) && packer fmt -recursive .

packer-fmt-check:
	$(call require_component)
	cd $(IMAGES_DIR)/$(COMPONENT) && packer fmt -recursive -check=true .

packer-validate: packer-init
	$(call require_component)
	cd $(IMAGES_DIR)/$(COMPONENT) && AWS_PROFILE=$(AWS_PROFILE) packer validate -evaluate-datasources $(PACKER_VARS) .

packer-build: packer-init
	$(call require_component)
	cd $(IMAGES_DIR)/$(COMPONENT) && AWS_PROFILE=$(AWS_PROFILE) packer build $(PACKER_VARS) .

packer-all:
	$(call require_component)
	$(MAKE) packer-init COMPONENT=$(COMPONENT)
	$(MAKE) packer-fmt-check COMPONENT=$(COMPONENT)
	$(MAKE) packer-validate COMPONENT=$(COMPONENT) AWS_PROFILE=$(AWS_PROFILE) SUBNET_ID=$(SUBNET_ID)
	$(MAKE) packer-build COMPONENT=$(COMPONENT) AWS_PROFILE=$(AWS_PROFILE) SUBNET_ID=$(SUBNET_ID)

# ---------------------------------------------------------------
# Runner log debugging
# ---------------------------------------------------------------
# Usage:
#   make logs GROUP=webhook                    # last 10 min of webhook logs
#   make logs GROUP=scale-up-terraform MINUTES=30  # last 30 min
#   make logs GROUP=runner-startup-general     # runner startup logs
#   make logs-list                             # show available log groups

logs-list:
	@echo "Available log groups (use with GROUP=<name>):"
	@echo ""
	@$(foreach g,$(LOG_GROUPS),echo "  $(g)	$(log-group-$(g))";)

logs:
	@if [ -z "$(GROUP)" ]; then \
		echo "Error: GROUP is required. Usage: make logs GROUP=<name> [MINUTES=10]"; \
		echo "Run 'make logs-list' to see available groups."; \
		exit 1; \
	fi
	@if [ -z "$(log-group-$(GROUP))" ]; then \
		echo "Error: Unknown group '$(GROUP)'. Run 'make logs-list' to see available groups."; \
		exit 1; \
	fi
	@START=$$(( $$(date +%s) * 1000 - $(MINUTES) * 60000 )); \
	AWS_PROFILE=$(AWS_PROFILE) aws logs filter-log-events \
		--region $(REGION) \
		--log-group-name "$(log-group-$(GROUP))" \
		--start-time $$START \
		--query 'events[*].message' \
		--output text
