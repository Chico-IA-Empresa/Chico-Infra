mock_provider "aws" {
  override_during = plan
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }
}
mock_provider "aws" {
  alias           = "billing"
  override_during = plan
}
variables {
  account_id                   = "123456789012"
  owner                        = "synthetic-only"
  cost_center                  = "synthetic-only"
  audit_bucket_name            = "synthetic-audit-only"
  audit_access_log_bucket_name = "synthetic-audit-access-only"
  access_log_retention_days    = 30
  audit_kms_key_arn            = "arn:aws:kms:sa-east-1:123456789012:key/synthetic-test"
  oidc_provider_arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_arn             = "arn:aws:s3:::synthetic-state-only"
  alert_emails                 = ["synthetic-only@example.invalid"]
  budget_limits                = { account = 200, shared = 10, dev = 10, uat = 60, prod = 120 }
  oidc_bindings = {
    ci-build-backend-dev  = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Back", environment = "release-dev", writable_state = false, state_access = false }
    ci-build-frontend-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Front", environment = "release-dev", writable_state = false, state_access = false }
  }
  credit_approval = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
}

run "adopts_the_six_hand_made_resources" {
  command = plan
  # Mock não importa: cada alvo dos blocos import recebe um override.
  override_resource {
    target          = module.oidc[0].aws_iam_role.ci["ci-build-backend-dev"]
    override_during = plan
  }
  override_resource {
    target          = module.oidc[0].aws_iam_role.ci["ci-build-frontend-dev"]
    override_during = plan
  }
  override_resource {
    target          = aws_iam_policy.backend_release_ci[0]
    override_during = plan
  }
  override_resource {
    target          = aws_iam_policy.frontend_release_ci[0]
    override_during = plan
  }
  override_resource {
    target          = aws_iam_role_policy_attachment.backend_release_ci[0]
    override_during = plan
  }
  override_resource {
    target          = aws_iam_role_policy_attachment.frontend_release_ci[0]
    override_during = plan
  }
  variables {
    provision_enabled   = true
    backend_release_ci  = { review_reference = "synthetic-only" }
    frontend_release_ci = { review_reference = "synthetic-only" }
  }
  assert {
    condition = jsonencode(local.release_ci_policy_arn) == jsonencode({
      backend  = "arn:aws:iam::123456789012:policy/chico/shared/chico-backend-release-ecr"
      frontend = "arn:aws:iam::123456789012:policy/chico/shared/chico-frontend-release-ecr"
    })
    error_message = "Os ARNs adotados são os das policies criadas à mão."
  }
  assert {
    condition     = length(aws_iam_policy.backend_release_ci) == 1 && length(aws_iam_policy.frontend_release_ci) == 1
    error_message = "Adotar não muda o que o código declara."
  }
}

run "nothing_to_adopt_when_disabled" {
  command = plan
  variables { provision_enabled = true }
  assert {
    condition     = length(local.release_ci_import) == 0
    error_message = "Sem os opt-ins, nenhum import."
  }
}

run "escape_hatch_for_a_fresh_account" {
  command = plan
  variables {
    provision_enabled          = true
    backend_release_ci         = { review_reference = "synthetic-only" }
    release_ci_import_existing = false
  }
  assert {
    condition     = length(local.release_ci_import) == 0 && length(aws_iam_policy.backend_release_ci) == 1
    error_message = "Conta nova: cria sem tentar importar."
  }
}
