# Optional identities for synthetic phase-1 proofs. No application deploy grant.
# This root owns the grants; module.oidc owns the exact trust and role resources.
variable "dev_proof_ci" {
  description = "Null keeps proof grants absent. Instance identity and nonsecret review reference must be reconciled privately before a specific Shared saved-plan review."
  type = object({
    instance_id      = string
    review_reference = string
  })
  default = null
  validation {
    condition = var.dev_proof_ci == null ? true : (
      can(regex("^i-([a-f0-9]{8}|[a-f0-9]{17})$", var.dev_proof_ci.instance_id)) &&
      length(trimspace(var.dev_proof_ci.review_reference)) > 0 &&
      !strcontains(var.dev_proof_ci.review_reference, "\n")
    )
    error_message = "Exact reviewed Dev instance ID and nonempty nonsecret review reference required."
  }
}

locals {
  dev_proof_ci_enabled = var.provision_enabled && var.dev_proof_ci != null
  dev_proof_ci_repositories = [for name in ["api", "workers", "frontend"] :
    "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-${name}"
  ]
  dev_proof_ci_policies = local.dev_proof_ci_enabled ? {
    build = {
      role = "ci-build-dev"
      document = jsonencode({ Version = "2012-10-17", Statement = [
        { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
        { Effect = "Allow", Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
          "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:DescribeImageScanFindings"
        ], Resource = local.dev_proof_ci_repositories },
        { Effect = "Allow", Action = ["ecr:GetRegistryScanningConfiguration"], Resource = "*" }
      ] })
    }
    status = {
      role = "ci-deploy-dev"
      document = jsonencode({ Version = "2012-10-17", Statement = [
        { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = ["arn:aws:ssm:sa-east-1:${var.account_id}:document/chico-dev-fixture-status"] },
        { Effect    = "Allow", Action = ["ssm:SendCommand"], Resource = ["arn:aws:ec2:sa-east-1:${var.account_id}:instance/${var.dev_proof_ci.instance_id}"],
          Condition = { StringEquals = { "ssm:resourceTag/env" = "dev", "ssm:resourceTag/project" = "chicoai" } }
        },
        { Effect    = "Allow", Action = ["ssm:GetCommandInvocation"], Resource = "*",
          Condition = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } }
        }
      ] })
    }
  } : {}
}

resource "aws_iam_policy" "dev_proof_ci" {
  for_each = local.dev_proof_ci_policies
  name     = "chico-dev-proof-${each.key}"
  path     = "/chico/shared/"
  policy   = each.value.document
  lifecycle {
    precondition {
      condition = try(
        var.oidc_bindings[each.value.role].scope == "dev" &&
        var.oidc_bindings[each.value.role].repository == "Chico-IA-Empresa/Chico-Infra" &&
        var.oidc_bindings[each.value.role].environment == "infra-apply-dev" &&
        !var.oidc_bindings[each.value.role].writable_state &&
        !var.oidc_bindings[each.value.role].state_access &&
        lookup(var.verified_oidc_subjects, each.value.role, "repo:Chico-IA-Empresa/Chico-Infra:environment:infra-apply-dev") == "repo:Chico-IA-Empresa/Chico-Infra:environment:infra-apply-dev",
      false)
      error_message = "Proof roles require exact Dev/repository/protected Environment subject and no state access or write. Customized subjects need a separate reviewed delta."
    }
  }
  depends_on = [module.funding]
}

resource "aws_iam_role_policy_attachment" "dev_proof_ci" {
  for_each   = local.dev_proof_ci_policies
  role       = each.value.role
  policy_arn = aws_iam_policy.dev_proof_ci[each.key].arn
  depends_on = [module.oidc]
}

output "dev_proof_ci_review" {
  value = local.dev_proof_ci_enabled ? {
    review_reference = var.dev_proof_ci.review_reference
    instance_id      = var.dev_proof_ci.instance_id
    policies         = { for name, value in local.dev_proof_ci_policies : name => jsondecode(value.document) }
    roles            = { for name, value in local.dev_proof_ci_policies : name => lookup(module.oidc[0].roles, value.role, null) }
    state_access     = false
    arbitrary_shell  = false
  } : null
}
