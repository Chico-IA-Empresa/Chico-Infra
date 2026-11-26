# Identidade OIDC de publicação da imagem do Chico-Front (par do
# backend-release-ci.tf). Só empurra e lê chico-frontend; não tem state, SSM,
# ECS nem segredos. Deploy continua sendo outra identidade, decidida depois.
# Este root concede a policy; module.oidc cria a role com trust exato.
variable "frontend_release_ci" {
  description = "Null deixa a policy ausente. A role vem do binding ci-build-frontend-dev em oidc_bindings."
  type = object({
    review_reference = string
  })
  default = null
  validation {
    condition = var.frontend_release_ci == null ? true : (
      length(trimspace(var.frontend_release_ci.review_reference)) > 0 &&
      !strcontains(var.frontend_release_ci.review_reference, "\n")
    )
    error_message = "Referência de revisão não secreta e não vazia obrigatória."
  }
}

locals {
  frontend_release_ci_enabled = var.provision_enabled && var.frontend_release_ci != null
  frontend_release_ci_role    = "ci-build-frontend-dev"
  frontend_release_ci_subject = "repo:Chico-IA-Empresa/Chico-Front:environment:release-dev"
  frontend_release_ci_repositories = [for name in ["frontend"] :
    "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-${name}"
  ]
}

resource "aws_iam_policy" "frontend_release_ci" {
  count = local.frontend_release_ci_enabled ? 1 : 0
  name  = "chico-frontend-release-ecr"
  path  = "/chico/shared/"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:DescribeImageScanFindings"
    ], Resource = local.frontend_release_ci_repositories },
    { Effect = "Allow", Action = ["ecr:GetRegistryScanningConfiguration"], Resource = "*" }
  ] })
  lifecycle {
    precondition {
      condition = try(
        var.oidc_bindings[local.frontend_release_ci_role].scope == "dev" &&
        var.oidc_bindings[local.frontend_release_ci_role].repository == "Chico-IA-Empresa/Chico-Front" &&
        var.oidc_bindings[local.frontend_release_ci_role].environment == "release-dev" &&
        !var.oidc_bindings[local.frontend_release_ci_role].writable_state &&
        !var.oidc_bindings[local.frontend_release_ci_role].state_access &&
        lookup(var.verified_oidc_subjects, local.frontend_release_ci_role, local.frontend_release_ci_subject) == local.frontend_release_ci_subject,
      false)
      error_message = "ci-build-frontend-dev exige Chico-Front, Environment release-dev, scope dev e nenhum acesso a state. Subject customizado precisa de delta revisado."
    }
  }
  depends_on = [module.funding]
}

resource "aws_iam_role_policy_attachment" "frontend_release_ci" {
  count      = local.frontend_release_ci_enabled ? 1 : 0
  role       = local.frontend_release_ci_role
  policy_arn = aws_iam_policy.frontend_release_ci[0].arn
  depends_on = [module.oidc]
}

output "frontend_release_ci_review" {
  value = local.frontend_release_ci_enabled ? {
    review_reference = var.frontend_release_ci.review_reference
    role_arn         = lookup(module.oidc[0].roles, local.frontend_release_ci_role, null)
    subject          = local.frontend_release_ci_subject
    repositories     = local.frontend_release_ci_repositories
    state_access     = false
  } : null
}
