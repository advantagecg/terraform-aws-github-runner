# Prebuilt Images

Pre-built Ubuntu 22.04 AMIs designed for ephemeral, single-job GitHub Actions runners. Using a pre-built image reduces runner startup time significantly compared to the user-data bootstrap path.

Both images share the same runner install/start scripts used by the user-data mechanism in `/modules/runners/templates/`, injected at build time via Packer's `templatefile()`.

---

## Available Images

### `ubuntu-general`

General-purpose CI/CD runner for AWS workloads.

| Tool | Details |
|---|---|
| OS | Ubuntu 22.04 LTS (Jammy) x86_64 |
| Docker CE | Latest stable from official Docker repo |
| AWS CLI v2 | Latest |
| Amazon CloudWatch agent | Latest |
| Node.js | LTS (via NodeSource) |
| Python 3 | + pip + venv |
| Common tools | git, curl, wget, jq, unzip, make, build-essential |

### `ubuntu-terraform`

Terraform/IaC CI/CD runner. Includes everything in `ubuntu-general` plus:

| Tool | Details |
|---|---|
| Terraform | Latest (managed via tfenv) |
| tfenv | Terraform version manager |
| Terragrunt | Latest |
| tflint | Latest |
| terraform-docs | Latest |
| Checkov | Latest (via pip) |
| infracost | Latest |

---

## Prerequisites

- [Packer](https://developer.hashicorp.com/packer/install) installed (`brew install packer`)
- AWS credentials configured for the target account
- AWS profile set up in `~/.aws/config`

---

## Building Images

All Packer commands are available from the **repo root** via `make`. The default AWS profile is `acg-main`.

```bash
# Initialise plugins (required once per machine)
make packer-init COMPONENT=ubuntu-general

# Validate configuration (dry-run, no AWS resources created)
make packer-validate COMPONENT=ubuntu-general

# Build the AMI
make packer-build COMPONENT=ubuntu-general

# Full pipeline: init → fmt-check → validate → build
make packer-all COMPONENT=ubuntu-general
```

To use a different AWS profile:

```bash
make packer-build COMPONENT=ubuntu-general AWS_PROFILE=my-other-profile
```

Replace `ubuntu-general` with `ubuntu-terraform` for the Terraform image.

---

## Using a Pre-built Image in Terraform

After a successful build, Packer outputs the AMI ID in `images/<component>/manifest.json`. Reference it in your runner module config:

**ubuntu-general:**
```hcl
ami_filter      = { name = ["github-runner-ubuntu-general-x86_64-*"] }
ami_owners      = ["<your-aws-account-id>"]
enable_userdata = false
```

**ubuntu-terraform:**
```hcl
ami_filter      = { name = ["github-runner-ubuntu-terraform-x86_64-*"] }
ami_owners      = ["<your-aws-account-id>"]
enable_userdata = false
```

Set `enable_userdata = false` so the module skips its bootstrap script — the AMI already has the runner pre-installed and the start script placed in `/var/lib/cloud/scripts/per-boot/`.

---

## AMI Cleanup

Old AMIs can be automatically deregistered using the [AMI housekeeper module](https://github-aws-runners.github.io/terraform-aws-github-runner/modules/public/ami-housekeeper/).
