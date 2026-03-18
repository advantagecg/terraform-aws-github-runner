# ---------------------------------------------------------------
# GitHub App credentials stored in Secrets Manager (single secret, JSON body)
#
# After first apply, populate via AWS CLI:
#
#   aws secretsmanager put-secret-value --profile acg-main --region us-east-1 \
#     --secret-id github-runner/github-app \
#     --secret-string '{"app_id":"YOUR_APP_ID","key_base64":"BASE64_ENCODED_KEY","webhook_secret":"YOUR_WEBHOOK_SECRET"}'
#
# To base64-encode the private key:
#   base64 -i app.private-key.pem | tr -d '\n'
# ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "github_app" {
  name        = "${local.prefix}/github-app"
  description = "GitHub App credentials for self-hosted runners"
  tags        = local.tags
}

data "aws_secretsmanager_secret_version" "github_app" {
  secret_id  = aws_secretsmanager_secret.github_app.id
  depends_on = [aws_secretsmanager_secret.github_app]
}

locals {
  github_app_secrets = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)
}
