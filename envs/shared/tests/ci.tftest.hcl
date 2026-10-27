mock_provider "aws" {
  override_during = plan
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::chico-infra-review-synthetic" }
  }
}
mock_provider "aws" {
  alias           = "billing"
  override_during = plan
}
variables {
  account_id                   = "123456789012"
  owner                        = "local-fixture"
  cost_center                  = "local-fixture"
  audit_bucket_name            = "synthetic-audit-only"
  audit_access_log_bucket_name = "synthetic-audit-access-only"
  access_log_retention_days    = 30
  audit_kms_key_arn            = "arn:aws:kms:sa-east-1:123456789012:key/synthetic-test"
  oidc_provider_arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_arn             = "arn:aws:s3:::synthetic-state-only"
  alert_emails                 = ["synthetic-only@example.invalid"]
  budget_limits                = { account = 200, shared = 10, dev = 10, uat = 60, prod = 120 }
  oidc_bindings = {
    ci-plan-dev        = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-plan-dev", writable_state = false }
    ci-infra-apply-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = true }
  }
  dev_ci_policy_documents = {
    plan             = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    apply_parts      = ["{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"]
    runtime_boundary = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    flow_boundary    = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
  }
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_policy.dev_infra) == 0 && length(aws_iam_policy.dev_boundary) == 0
    error_message = "Grants e boundaries não podem ignorar provision_enabled."
  }
}
run "segregated_ci_bindings" {
  command = plan
  variables {
    provision_enabled = true
    credit_approval   = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  assert {
    condition     = length(aws_iam_policy.dev_boundary) == 2 && aws_iam_role_policy_attachment.dev_infra["plan"].role == "ci-plan-dev" && aws_iam_role_policy_attachment.dev_infra["apply-0"].role == "ci-infra-apply-dev"
    error_message = "Plan/apply precisam de roles distintas e boundaries shared próprias."
  }
}
run "reject_plan_writable_state_and_foreign_repo" {
  command = plan
  variables {
    provision_enabled = true
    credit_approval   = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    oidc_bindings = {
      ci-plan-dev        = { scope = "dev", repository = "foreign/infra", environment = "infra-plan-dev", writable_state = true }
      ci-infra-apply-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = true }
    }
  }
  expect_failures = [aws_iam_policy.dev_infra["plan"]]
}
run "initial_shared_foundation_without_vpc_grants" {
  command = plan
  variables {
    provision_enabled             = true
    foundation_enabled            = true
    audit_kms_key_arn             = null
    oidc_provider_arn             = null
    dev_ci_policy_documents       = null
    review_bucket_name            = "chico-infra-review-synthetic"
    review_access_log_bucket_name = "chico-review-access-synthetic"
    credit_approval               = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  assert {
    condition     = length(aws_kms_key.foundation) == 4 && alltrue([for key in aws_kms_key.foundation : key.enable_key_rotation && key.deletion_window_in_days == 30]) && length(aws_iam_policy.dev_infra) == 0
    error_message = "Foundation precisa de quatro CMKs protegidas, sem grants dependentes de VPC ainda inexistente."
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "Shared deve criar um único issuer GitHub com audience exata."
  }
  assert {
    condition     = jsondecode(aws_kms_key.foundation["logs"].policy).Statement[1].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"] == local.log_contexts.logs && jsondecode(aws_kms_key.foundation["alerts"].policy).Statement[1].Condition.ArnEquals["aws:SourceArn"] == local.dev_alarm_arns
    error_message = "Logs e alarmes não podem usar principals/contextos de outros ambientes."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.review[0].restrict_public_buckets && aws_s3_bucket_versioning.review[0].versioning_configuration[0].status == "Enabled" && one(aws_s3_bucket_server_side_encryption_configuration.review[0].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256" && aws_s3_bucket_logging.review[0].target_prefix == "access/review/"
    error_message = "Planos reais exigem bucket privado, versionado, AES256 compatível com workflow e logging correto."
  }
  assert {
    condition     = length(aws_sns_topic_subscription.dev_operations) == 1 && jsondecode(aws_sns_topic_policy.dev_operations[0].policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == local.dev_alarm_arns
    error_message = "Alertas exigem destino definido e publicação limitada aos alarmes Dev autorizados."
  }
}
run "cost_tag_cannot_bypass_provision_gate" {
  command = plan
  variables {
    activate_environment_cost_tag           = true
    environment_cost_tag_evidence_reference = "synthetic-mock-only"
  }
  assert {
    condition     = length(aws_ce_cost_allocation_tag.environment) == 0
    error_message = "Opt-in de cost allocation não pode ignorar provision_enabled."
  }
}
run "cost_tag_requires_reviewed_evidence" {
  command = plan
  variables {
    provision_enabled             = true
    activate_environment_cost_tag = true
    credit_approval               = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  expect_failures = [aws_ce_cost_allocation_tag.environment[0]]
}
run "cost_tag_activation_is_scoped_and_explicit" {
  command = plan
  variables {
    provision_enabled                       = true
    activate_environment_cost_tag           = true
    environment_cost_tag_evidence_reference = "synthetic-mock-only"
    credit_approval                         = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  assert {
    condition     = aws_ce_cost_allocation_tag.environment[0].tag_key == "env" && aws_ce_cost_allocation_tag.environment[0].status == "Active"
    error_message = "Shared ativa somente env após opt-in/evidência; nenhum outro tag ou cobrança é alterado."
  }
}
