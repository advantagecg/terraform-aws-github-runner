<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.21 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.21 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_ami_housekeeper"></a> [ami\_housekeeper](#module\_ami\_housekeeper) | ../modules/ami-housekeeper | n/a |
| <a name="module_runners"></a> [runners](#module\_runners) | ../modules/multi-runner | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_secretsmanager_secret.github_app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.github_app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_webhook_endpoint"></a> [webhook\_endpoint](#output\_webhook\_endpoint) | Webhook URL — set this as the Webhook URL in your GitHub App settings |
| <a name="output_webhook_secret_ssm_path"></a> [webhook\_secret\_ssm\_path](#output\_webhook\_secret\_ssm\_path) | SSM parameter path where the webhook secret is stored |
<!-- END_TF_DOCS -->