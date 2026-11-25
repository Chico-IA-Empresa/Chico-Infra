# Identidade OIDC de publicação de imagens do Chico-Back (WORK/API release-dev).
# Só empurra e lê chico-api e chico-workers; não tem state, SSM, ECS nem
# segredos. Deploy continua sendo outra identidade, decidida depois.
# Este root concede a policy; module.oidc cria a role com trust exato.
variable "backend_release_ci" {
  description = "Null deixa a policy ausente. A role vem do binding ci-build-backend-dev em oidc_bindings."
  type = object({
    review_reference = string
  })
  default = null
  validation {
    condition = var.backend_release_ci == null ? true : (
      length(trimspace(var.backend_release_ci.review_reference)) > 0 &&
      !strcontains(var.backend_release_ci.review_reference, "\n")
    )
    error_message = "Referência de revisão não secreta e não vazia obrigatória."
  }
}

locals {
  backend_release_ci_enabled = var.provision_enabled && var.backend_release_ci != null
  backend_release_ci_role    = "ci-build-backend-dev"
  backend_release_ci_subject = "repo:Chico-IA-Empresa/Chico-Back:environment:release-dev"
  backend_release_ci_repositories = [for name in ["api", "workers"] :
    "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-${name}"
  ]
}

resource "aws_iam_policy" "backend_release_ci" {
  count = local.backend_release_ci_enabled ? 1 : 0
  name  = "chico-backend-release-ecr"
  path  = "/chico/shared/"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:DescribeImageScanFindings"
    ], Resource = local.backend_release_ci_repositories },
    { Effect = "Allow", Action = ["ecr:GetRegistryScanningConfiguration"], Resource = "*" }
  ] })
  lifecycle {
    precondition {
      condition = try(
        var.oidc_bindings[local.backend_release_ci_role].scope == "dev" &&
        var.oidc_bindings[local.backend_release_ci_role].repository == "Chico-IA-Empresa/Chico-Back" &&
        var.oidc_bindings[local.backend_release_ci_role].environment == "release-dev" &&
        !var.oidc_bindings[local.backend_release_ci_role].writable_state &&
        !var.oidc_bindings[local.backend_release_ci_role].state_access &&
        lookup(var.verified_oidc_subjects, local.backend_release_ci_role, local.backend_release_ci_subject) == local.backend_release_ci_subject,
      false)
      error_message = "ci-build-backend-dev exige Chico-Back, Environment release-dev, scope dev e nenhum acesso a state. Subject customizado precisa de delta revisado."
    }
  }
  depends_on = [module.funding]
}

resource "aws_iam_role_policy_attachment" "backend_release_ci" {
  count      = local.backend_release_ci_enabled ? 1 : 0
  role       = local.backend_release_ci_role
  policy_arn = aws_iam_policy.backend_release_ci[0].arn
  depends_on = [module.oidc]
}

output "backend_release_ci_review" {
  value = local.backend_release_ci_enabled ? {
    review_reference = var.backend_release_ci.review_reference
    role_arn         = lookup(module.oidc[0].roles, local.backend_release_ci_role, null)
    subject          = local.backend_release_ci_subject
    repositories     = local.backend_release_ci_repositories
    state_access     = false
  } : null
}
