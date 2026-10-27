variable "dev_ci_policy_documents" {
  description = "Reviewed candidates generated from reconciled metadata; null leaves CI grants/boundaries absent. Never populate with fixture inventory."
  type = object({
    plan             = string
    apply_parts      = list(string)
    runtime_boundary = string
    flow_boundary    = string
  })
  default = null
}
locals {
  dev_ci_enabled = var.provision_enabled && var.dev_ci_policy_documents != null
  dev_ci_policies = local.dev_ci_enabled ? merge(
    { plan = { role = "ci-plan-dev", document = var.dev_ci_policy_documents.plan } },
    { for index, policy in var.dev_ci_policy_documents.apply_parts : "apply-${index}" => { role = "ci-infra-apply-dev", document = policy } }
  ) : {}
}
resource "aws_iam_policy" "dev_boundary" {
  for_each = local.dev_ci_enabled ? { runtime = var.dev_ci_policy_documents.runtime_boundary, flow = var.dev_ci_policy_documents.flow_boundary } : {}
  name     = "chico-dev-${each.key}-boundary"
  path     = "/chico/shared/"
  policy   = each.value
  lifecycle { prevent_destroy = true }
  depends_on = [module.funding]
}
resource "aws_iam_policy" "dev_infra" {
  for_each = local.dev_ci_policies
  name     = "chico-dev-infra-${each.key}"
  path     = "/chico/shared/"
  policy   = each.value.document
  lifecycle {
    precondition {
      condition = length(each.value.document) <= 6144 && try(
        var.oidc_bindings[each.value.role].scope == "dev" &&
        var.oidc_bindings[each.value.role].repository == "Chico-IA-Empresa/Chico-Infra" &&
        var.oidc_bindings[each.value.role].environment == (each.value.role == "ci-plan-dev" ? "infra-plan-dev" : "infra-apply-dev") &&
        var.oidc_bindings[each.value.role].writable_state == (each.value.role != "ci-plan-dev"), false
      )
      error_message = "Policy até 6144 caracteres e binding Dev do Chico-Infra com Environment/state segregados são obrigatórios."
    }
  }
  depends_on = [module.funding]
}
resource "aws_iam_role_policy_attachment" "dev_infra" {
  for_each   = local.dev_ci_policies
  role       = each.value.role
  policy_arn = aws_iam_policy.dev_infra[each.key].arn
  depends_on = [module.oidc, aws_iam_policy.dev_boundary]
}
output "dev_runtime_boundary_arns" {
  value = local.dev_ci_enabled ? { for name, policy in aws_iam_policy.dev_boundary : name => policy.arn } : null
}
