resource "aws_iam_role_policy" "configuration" {
  count = local.host_enabled && (length(var.secret_names) + length(var.parameters) > 0) ? 1 : 0
  role  = aws_iam_role.runtime[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [for statement in [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = values(module.configuration[0].secret_arns) },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [var.secrets_key_arn], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.sa-east-1.amazonaws.com" }, StringLike = { "kms:EncryptionContext:SecretARN" = "arn:aws:secretsmanager:sa-east-1:${var.account_id}:secret:/chico/dev/*" } } }
    ] : statement if length(var.secret_names) > 0],
    [for statement in [
      { Effect = "Allow", Action = ["ssm:GetParameters"], Resource = [for name in keys(var.parameters) : "arn:aws:ssm:sa-east-1:${var.account_id}:parameter/chico/dev/${name}"] }
    ] : statement if length(var.parameters) > 0]
  ) })
  lifecycle {
    precondition {
      condition     = length(var.secret_names) == 0 || can(regex("^arn:aws:kms:sa-east-1:${var.account_id}:key/[a-zA-Z0-9-]+$", var.secrets_key_arn))
      error_message = "CMK Dev da conta aprovada obrigatória para secrets."
    }
  }
}
