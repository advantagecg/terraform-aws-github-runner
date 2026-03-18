# System Review: terraform-aws-github-runner

**Date:** 2026-03-18
**Reviewer:** Claude (assisted)
**Scope:** Full architecture review of the self-hosted GitHub Actions runner infrastructure deployed for `@advantagecg`

---

## Architecture Overview

```
GitHub App (webhook) --> API Gateway --> Webhook Lambda --> EventBridge --> SQS (per runner type)
                                                                             |
                                                                        Scale-Up Lambda
                                                                             |
                                                                    EC2 CreateFleet (Spot)
                                                                             |
                                                                     Runner Instance
                                                                    (ephemeral, JIT config)
                                                                             |
                                                                     Job completes --> self-terminates
```

**Runner types:** `ubuntu-general` (20GB, full CI/CD toolchain) and `ubuntu-terraform` (8GB, Terraform toolchain)
**Region:** us-east-1 | **Account:** 174647940105 | **Prefix:** github-runner

---

## P0 -- Broken / Fixed During Rollout

| Issue | Impact | Status | Fix Applied |
|-------|--------|--------|-------------|
| `log_class` in CloudWatch agent config | Instances fail startup, runner never starts | Fixed | Stripped `log_class` from agent config in `modules/runners/logging.tf`; kept it for log group resource |
| Duplicate fleet pools (same-AZ subnets) | `InvalidFleetConfig` error, no instances launch | Fixed | Changed `lowest-price` to `capacity-optimized`; reduced to 1 subnet (both were in us-east-1d) |
| Stuck GitHub Actions jobs | Jobs queue forever after SQS message consumed but instance fails | Fixed | Enabled DLQ (`maxReceiveCount: 3`) and `enable_job_retry` on both runner configs |
| Force-cancelled stuck workflow runs | 3 runs stuck in `queued` state indefinitely | Fixed | Used `gh api -X POST .../force-cancel` |

---

## P1 -- Security & Reliability

### Secrets in Terraform State

**Severity:** High
**Current state:** `secrets.tf` reads GitHub App credentials from Secrets Manager via `data.aws_secretsmanager_secret_version`, which stores the plaintext values in Terraform state.

```hcl
# Current (secrets leak into state):
locals {
  github_app_secrets = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)
}
```

**Recommendation:** Refactor so Lambdas read from Secrets Manager directly at runtime. Terraform should only manage the secret ARN, not the value. Alternatively, populate SSM SecureString parameters outside of Terraform and reference only the parameter name.

### No CloudWatch Alarms

**Severity:** High
**Current state:** Metrics are emitted (GitHub App rate limit, spot termination warnings) but no alarms are configured. Lambda errors, SQS queue depth, and scaling failures all fail silently.

**Recommendation:** Create `production/monitoring.tf` with alarms for:
- Lambda errors > 0 (webhook, scale-up, scale-down, pool, SSM housekeeper)
- SQS `ApproximateNumberOfMessagesVisible` > 10 (queue backing up)
- SQS DLQ `ApproximateNumberOfMessagesVisible` > 0 (failed messages)
- GitHub App rate limit remaining < 1000
- Scale-up Lambda duration > 10s

Route all to an SNS topic with email/Slack.

### No SNS Notifications

**Severity:** High
**Current state:** No alerting channel configured. No way to know when things break.

**Recommendation:** Create SNS topic + subscription as part of monitoring.tf.

### Webhook Endpoint Security

**Severity:** Medium
**Current state:** API Gateway is a public HTTPS endpoint. Authentication relies solely on GitHub webhook signature validation inside the Lambda function.

**Recommendation:**
- Enable API Gateway access logging
- Consider WAF rate limiting
- Optionally restrict to [GitHub webhook IP ranges](https://api.github.com/meta)

### Encryption

**Severity:** Medium
**Current state:** All encryption uses AWS-managed keys (default). No customer-managed KMS keys.

**Recommendation:** Create customer-managed KMS key for:
- `logging_kms_key_id` (CloudWatch logs)
- SQS queue encryption
- EBS volume encryption (`kms_key_id` in `block_device_mappings`)

### IAM Permissions Boundary

**Severity:** Medium
**Current state:** Runner IAM role has no permissions boundary set.

**Recommendation:** Set `role_permissions_boundary` to limit the maximum permissions any runner can assume.

---

## P2 -- Operational Gaps

### Single Availability Zone

**Severity:** High
**Current state:** VPC subnets are both in `us-east-1d`. Reduced to 1 subnet to avoid fleet duplicate pool errors.

**Recommendation:** Create subnets in at least 2 different AZs. This provides fault tolerance and allows `capacity-optimized` fleet allocation to spread across zones.

### No Packer Build Automation

**Severity:** Medium
**Current state:** AMIs built manually via `make packer-build COMPONENT=<name>`. The CI workflow (`.github/workflows/packer-build.yml`) only validates -- it does not build.

**Recommendation:** Add a build step to the CI workflow triggered on merge to main when `images/` changes. Store the AMI ID as a workflow artifact. Optionally auto-update the SSM parameter with the new AMI ID.

### Non-Deterministic Packer Builds

**Severity:** Medium
**Current state:** No package version pinning. `apt-get install` pulls latest. Ruby version determined at build time. GitHub API calls for latest releases may hit rate limits.

**Recommendation:**
- Pin critical package versions (Docker CE, Node.js, Terraform)
- Add SHA256 checksum verification for binary downloads (AWS CLI, CloudWatch agent, Session Manager plugin)
- Remove `curl | bash` patterns (tflint installer)

### Aggressive Scale-Down Schedule

**Severity:** Low
**Current state:** `cron(* * * * ? *)` runs the scale-down Lambda every minute.

**Recommendation:** Change to `cron(*/5 * * * ? *)` (every 5 minutes). Ephemeral runners self-terminate on job completion; the scale-down Lambda only catches stragglers. Every-minute invocation adds unnecessary Lambda cost and API calls.

### No Operational Runbook

**Severity:** Medium
**Current state:** No documented procedures for debugging failures.

**Recommendation:** Create runbook covering:
- Debugging "runner won't start" (check runner-startup log group)
- Debugging "webhook not receiving events" (check webhook log group, GitHub App settings)
- Force-cancelling stuck runs (`gh api -X POST .../force-cancel`)
- Manually scaling up/down
- Rolling back AMI (update AMI filter or pin AMI ID)
- Log group reference table (see appendix)

### No Cost Budgets

**Severity:** Low
**Current state:** No AWS Budget alarms configured. Runners could scale to max (10 per type, 20 total) with no cost guardrails.

**Recommendation:** Set AWS Budget alarm for the runner infrastructure tag (`Project: github-runners`).

---

## P3 -- Future Improvements

| Item | Notes |
|------|-------|
| Multi-region DR | Single region deployment; no failover |
| Blue-green AMI rollout | New AMI immediately used by all runners; no canary |
| Tighter provider pinning | `~> 6.21` allows minor upgrades that could break |
| VPC flow logs | No network audit trail |
| Upstream log_class fix | Local fix in `modules/runners/logging.tf` will conflict on module upgrades |
| Terraform plan CI gate | No automated plan review for production changes |
| Secrets rotation | GitHub App credentials are static; no rotation policy |

---

## What's Working Well

- Ephemeral runner lifecycle (JIT config, self-termination, credential cleanup)
- Spot instances with capacity-optimized allocation and on-demand failover
- EventBridge-based webhook routing (better filtering than direct SQS)
- Business hours warm pool (2 runners 9am-6pm ET Mon-Fri)
- AMI housekeeper (30-day cleanup, launch template protection)
- CloudWatch agent streaming runner logs to CloudWatch
- Pre-built AMIs with runner binary pre-installed (fast cold start ~90s)
- Comprehensive Lambda test coverage (66 test files, Vitest)
- Security scanning in CI (CodeQL, OSV, OSSF Scorecard, zizmor)
- Signed release artifacts with SLSA provenance attestation

---

## Appendix: Log Group Reference

| Short Name | Log Group | What It Shows |
|------------|-----------|---------------|
| `webhook` | `/aws/lambda/github-runner-webhook` | Incoming webhook events from GitHub |
| `scale-up-general` | `/aws/lambda/github-runner-ubuntu-general-scale-up` | Scale-up decisions for general runners |
| `scale-up-terraform` | `/aws/lambda/github-runner-ubuntu-terraform-scale-up` | Scale-up decisions for terraform runners |
| `scale-down-general` | `/aws/lambda/github-runner-ubuntu-general-scale-down` | Scale-down / orphan cleanup for general |
| `scale-down-terraform` | `/aws/lambda/github-runner-ubuntu-terraform-scale-down` | Scale-down / orphan cleanup for terraform |
| `runner-startup-general` | `/github-self-hosted-runners/github-runner-ubuntu-general/runner-startup` | Instance boot, CW agent, runner registration |
| `runner-startup-terraform` | `/github-self-hosted-runners/github-runner-ubuntu-terraform/runner-startup` | Instance boot, CW agent, runner registration |
| `runner-general` | `/github-self-hosted-runners/github-runner-ubuntu-general/runner` | Runner agent diagnostic logs |
| `runner-terraform` | `/github-self-hosted-runners/github-runner-ubuntu-terraform/runner` | Runner agent diagnostic logs |

Access via Makefile: `make logs GROUP=<short-name> MINUTES=<n>`

---

## Appendix: Timeline Analysis (Cold Start)

Measured from the first successful run of "Detect Changed Components" on `ubuntu-terraform`:

| Phase | Duration | Cumulative |
|-------|----------|------------|
| GitHub queues job | 0s | 0s |
| Webhook received (GitHub -> API Gateway -> Lambda) | 1s | 1s |
| EventBridge -> SQS -> Scale-up Lambda | 3s | 4s |
| Scale-up Lambda (auth, runner count check) | 1s | 5s |
| EC2 CreateFleet response | 2s | 7s |
| Instance boot + cloud-init + start-runner.sh | 47s | 54s |
| CloudWatch agent configure + start | 22s | 76s |
| JIT runner registration + connect to GitHub | 13s | 89s |
| Job pickup | 0s | 89s |
| **Job execution** | **8s** | **97s** |

**Cold start overhead: ~89s** (eliminated by warm pool during business hours)
