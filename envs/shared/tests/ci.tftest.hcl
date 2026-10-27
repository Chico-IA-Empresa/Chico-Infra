mock_provider "aws" {}
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
