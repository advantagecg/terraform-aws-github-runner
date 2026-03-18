output "webhook_endpoint" {
  description = "Webhook URL — set this as the Webhook URL in your GitHub App settings"
  value       = module.runners.webhook.endpoint
}

output "webhook_secret_ssm_path" {
  description = "SSM parameter path where the webhook secret is stored"
  value       = module.runners.ssm_parameters
}
