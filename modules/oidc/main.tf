variable "provider_arn" { type = string }
variable "state_bucket_arn" { type = string }
variable "bindings" {
  description = "Exact GitHub Environment subject per role. Permissions beyond state are granted only after ARN inventory review."
  type        = map(object({ scope = string, repository = string, environment = string, writable_state = bool, state_access = optional(bool, true) }))
  validation {
    condition     = alltrue([for b in values(var.bindings) : contains(["shared", "dev", "uat", "prod"], b.scope) && can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", b.repository)) && can(regex("^[a-z0-9-]+$", b.environment)) && (!b.writable_state || b.state_access)])
    error_message = "Use scope válido e repo/environment exatos, sem wildcard."
  }
  validation {
    condition     = alltrue([for name, binding in var.bindings : !binding.state_access || contains(["ci-plan-${binding.scope}", "ci-infra-apply-${binding.scope}"], name)])
    error_message = "Somente ci-plan-SCOPE/ci-infra-apply-SCOPE recebem state; build/deploy devem declarar state_access=false."
  }
}
variable "verified_subjects" {
  description = "Exact observed subjects for repositories using customized/immutable-ID OIDC claims; never a token. Key must match a binding."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k, subject in var.verified_subjects : contains(keys(var.bindings), k) && startswith(subject, "repo") && !strcontains(subject, "*") && !strcontains(subject, "?") && !strcontains(subject, "\n") && length(subject) <= 255])
    error_message = "Subject observado exato, sem wildcard, de binding existente."
  }
}
resource "aws_iam_role" "ci" {
  for_each             = var.bindings
  name                 = each.key
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Federated = var.provider_arn }, Action = "sts:AssumeRoleWithWebIdentity",
    Condition = { StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = lookup(var.verified_subjects, each.key, "repo:${each.value.repository}:environment:${each.value.environment}")
    } }
  }] })
}
resource "aws_iam_role_policy" "state" {
  for_each = { for name, binding in var.bindings : name => binding if binding.state_access }
  role     = aws_iam_role.ci[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = var.state_bucket_arn,
    Condition = { StringLike = { "s3:prefix" = ["${each.value.scope}/terraform.tfstate", "${each.value.scope}/terraform.tfstate.tflock"] } } },
    { Effect = "Allow", Action = each.value.writable_state ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"],
    Resource = "${var.state_bucket_arn}/${each.value.scope}/terraform.tfstate" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
    Resource = "${var.state_bucket_arn}/${each.value.scope}/terraform.tfstate.tflock" }
  ] })
}
output "roles" { value = { for k, v in aws_iam_role.ci : k => v.arn } }
