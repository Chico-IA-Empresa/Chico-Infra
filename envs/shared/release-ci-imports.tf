# Os papéis de publicação (backend-release-ci.tf e frontend-release-ci.tf)
# foram criados à mão pela API em 2026-11-26, com nomes, documentos e tags
# iguais ao código, para os releases funcionarem antes do apply do Shared.
# Estes blocos fazem o próximo plan ADOTAR esses 6 recursos ("to import") em
# vez de tentar criá-los e falhar com "já existe". Depois do primeiro apply eles
# não fazem mais nada. Numa conta onde os recursos não existem, desligar com
# release_ci_import_existing = false.
variable "release_ci_import_existing" {
  description = "Adota no state os papéis de publicação já criados na conta. False numa conta onde eles não existem."
  type        = bool
  default     = true
}

locals {
  release_ci_import = var.release_ci_import_existing ? merge(
    local.backend_release_ci_enabled ? { backend = { role = local.backend_release_ci_role, policy = "chico-backend-release-ecr" } } : {},
    local.frontend_release_ci_enabled ? { frontend = { role = local.frontend_release_ci_role, policy = "chico-frontend-release-ecr" } } : {},
  ) : {}
  release_ci_policy_arn = { for key, item in local.release_ci_import : key => "arn:aws:iam::${var.account_id}:policy/chico/shared/${item.policy}" }
}

import {
  for_each = local.release_ci_import
  to       = module.oidc[0].aws_iam_role.ci[each.value.role]
  id       = each.value.role
}

import {
  for_each = contains(keys(local.release_ci_import), "backend") ? { only = 0 } : {}
  to       = aws_iam_policy.backend_release_ci[each.value]
  id       = local.release_ci_policy_arn["backend"]
}

import {
  for_each = contains(keys(local.release_ci_import), "backend") ? { only = 0 } : {}
  to       = aws_iam_role_policy_attachment.backend_release_ci[each.value]
  id       = "${local.backend_release_ci_role}/${local.release_ci_policy_arn["backend"]}"
}

import {
  for_each = contains(keys(local.release_ci_import), "frontend") ? { only = 0 } : {}
  to       = aws_iam_policy.frontend_release_ci[each.value]
  id       = local.release_ci_policy_arn["frontend"]
}

import {
  for_each = contains(keys(local.release_ci_import), "frontend") ? { only = 0 } : {}
  to       = aws_iam_role_policy_attachment.frontend_release_ci[each.value]
  id       = "${local.frontend_release_ci_role}/${local.release_ci_policy_arn["frontend"]}"
}
