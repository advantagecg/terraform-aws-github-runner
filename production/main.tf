locals {
  prefix     = "github-runner"
  aws_region = "us-east-1"
  vpc_id     = "vpc-0ff283cd4cdf77408"
  # Both original subnets are in us-east-1d — using one to avoid duplicate fleet pools
  subnet_ids = ["subnet-01dfcb1d9383291da"]
  account_id = "174647940105"

  tags = {
    Project     = "github-runners"
    Environment = "production"
    ManagedBy   = "terraform"
  }

  # Business hours pool schedule (America/New_York)
  pool_config = [
    {
      # Scale up to 2 runners at 9am Mon-Fri
      schedule_expression          = "cron(0 9 ? * MON-FRI *)"
      schedule_expression_timezone = "America/New_York"
      size                         = 2
    },
    {
      # Scale down to 0 at 6pm Mon-Fri
      schedule_expression          = "cron(0 18 ? * MON-FRI *)"
      schedule_expression_timezone = "America/New_York"
      size                         = 0
    }
  ]

  # CloudWatch log files streamed from each runner instance
  runner_log_files = [
    {
      log_group_name   = "runner-startup"
      prefix_log_group = true
      file_path        = "/var/log/runner-startup.log"
      log_stream_name  = "{instance_id}"
    },
    {
      log_group_name   = "runner"
      prefix_log_group = true
      file_path        = "/opt/actions-runner/_diag/Runner_**.log"
      log_stream_name  = "{instance_id}/runner"
    }
  ]
}

module "runners" {
  source = "../modules/multi-runner"

  prefix     = local.prefix
  aws_region = local.aws_region
  vpc_id     = local.vpc_id
  subnet_ids = local.subnet_ids
  tags       = local.tags

  github_app = {
    key_base64     = local.github_app_secrets["key_base64"]
    id             = local.github_app_secrets["app_id"]
    webhook_secret = local.github_app_secrets["webhook_secret"]
  }

  # Route webhook events through EventBridge (recommended default)
  eventbridge = {
    enable        = true
    accept_events = ["workflow_job"]
  }

  # CloudWatch log retention
  logging_retention_in_days = 90

  # CloudWatch metrics (rate limit, spot terminations)
  metrics = {
    enable = true
    metric = {
      enable_github_app_rate_limit    = true
      enable_job_retry                = true
      enable_spot_termination_warning = true
    }
  }

  multi_runner_config = {

    # ---------------------------------------------------------------
    # ubuntu-general: General CI/CD runner
    # Labels: self-hosted, linux, x64, ubuntu-general
    # AMI: github-runner-ubuntu-general-x86_64-* (20GB, full toolchain)
    # ---------------------------------------------------------------
    "ubuntu-general" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "linux", "x64", "ubuntu-general"]]
        exactMatch    = true
      }
      fifo = true
      redrive_build_queue = {
        enabled         = true
        maxReceiveCount = 10
      }
      runner_config = {
        runner_os           = "linux"
        runner_architecture = "x64"
        runner_run_as       = "ubuntu"
        runner_name_prefix  = "general-"

        # Org-level ephemeral runners with JIT tokens
        enable_organization_runners = true
        enable_ephemeral_runners    = true
        enable_jit_config           = true
        enable_job_queued_check     = false

        runners_maximum_count = 25

        # Allow up to 10 concurrent scale-up Lambda invocations (default is 1, which serializes job processing)
        scale_up_reserved_concurrent_executions = 10

        # No webhook delay for ephemeral (no idle runners to wait for)
        delay_webhook_event = 0

        # Aggressive orphan cleanup (ephemeral runners self-terminate, this catches stragglers)
        scale_down_schedule_expression = "cron(* * * * ? *)"

        # Spot with on-demand fallback on capacity errors
        instance_types                       = ["m5.large", "m5a.large", "t3.large"]
        instance_target_capacity_type        = "spot"
        instance_allocation_strategy         = "capacity-optimized"
        enable_on_demand_failover_for_errors = ["InsufficientInstanceCapacity"]

        # Pre-built AMI — runner binary already installed, skip user-data bootstrap
        enable_userdata = false
        ami = {
          owners = [local.account_id]
          filter = {
            name  = ["github-runner-ubuntu-general-x86_64-*"]
            state = ["available"]
          }
        }

        # Root volume matches what was set during Packer build
        block_device_mappings = [{
          device_name           = "/dev/sda1"
          delete_on_termination = true
          volume_type           = "gp3"
          volume_size           = 20
          encrypted             = true
          iops                  = null
          throughput            = null
          kms_key_id            = null
          snapshot_id           = null
        }]

        enable_cloudwatch_agent = true
        runner_log_files        = local.runner_log_files

        # TODO: Scope down to least-privilege policy
        runner_iam_role_managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]

        # Warm pool: 2 runners during business hours (9am-6pm ET, Mon-Fri)
        pool_config = local.pool_config
      }
    }

    # ---------------------------------------------------------------
    # ubuntu-terraform: Terraform/IaC runner
    # Labels: self-hosted, linux, x64, ubuntu-terraform
    # AMI: github-runner-ubuntu-terraform-x86_64-* (8GB, Terraform toolchain)
    # ---------------------------------------------------------------
    "ubuntu-terraform" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "linux", "x64", "ubuntu-terraform"]]
        exactMatch    = true
      }
      fifo = true
      redrive_build_queue = {
        enabled         = true
        maxReceiveCount = 10
      }
      runner_config = {
        runner_os           = "linux"
        runner_architecture = "x64"
        runner_run_as       = "ubuntu"
        runner_name_prefix  = "terraform-"

        # Org-level ephemeral runners with JIT tokens
        enable_organization_runners = true
        enable_ephemeral_runners    = true
        enable_jit_config           = true
        enable_job_queued_check     = false

        runners_maximum_count = 25

        # Allow up to 10 concurrent scale-up Lambda invocations
        scale_up_reserved_concurrent_executions = 10

        delay_webhook_event            = 0
        scale_down_schedule_expression = "cron(* * * * ? *)"

        instance_types                       = ["m5.large", "m5a.large", "t3.large"]
        instance_target_capacity_type        = "spot"
        instance_allocation_strategy         = "capacity-optimized"
        enable_on_demand_failover_for_errors = ["InsufficientInstanceCapacity"]

        enable_userdata = false
        ami = {
          owners = [local.account_id]
          filter = {
            name  = ["github-runner-ubuntu-terraform-x86_64-*"]
            state = ["available"]
          }
        }

        block_device_mappings = [{
          device_name           = "/dev/sda1"
          delete_on_termination = true
          volume_type           = "gp3"
          volume_size           = 8
          encrypted             = true
          iops                  = null
          throughput            = null
          kms_key_id            = null
          snapshot_id           = null
        }]

        enable_cloudwatch_agent = true
        runner_log_files        = local.runner_log_files

        # TODO: Scope down to least-privilege policy
        runner_iam_role_managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]

        # Warm pool: 2 runners during business hours (9am-6pm ET, Mon-Fri)
        pool_config = local.pool_config
      }
    }
  }
}

# ---------------------------------------------------------------
# AMI Housekeeper — deregisters AMIs older than 30 days
# ---------------------------------------------------------------
module "ami_housekeeper" {
  source = "../modules/ami-housekeeper"

  prefix = local.prefix
  tags   = local.tags

  cleanup_config = {
    dryRun         = false
    minimumDaysOld = 30
    filters = [
      {
        name   = "name"
        values = ["github-runner-ubuntu-general-x86_64-*", "github-runner-ubuntu-terraform-x86_64-*"]
      },
      {
        name   = "state"
        values = ["available"]
      }
    ]
    # Protect AMIs currently referenced by launch templates
    launchTemplateNames = ["ghr-*"]
  }
}
