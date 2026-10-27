mock_provider "aws" {}
variables {
  provider_arn     = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_arn = "arn:aws:s3:::test-only-state"
  bindings = {
    ci-plan-uat = { scope = "uat", repository = "test-only/infra", environment = "infra-plan-uat", writable_state = false }
  }
}
run "immutable_subject" {
  command = plan
  variables {
    verified_subjects = { ci-plan-uat = "repository_id:12345:environment:infra-plan-uat" }
  }
  assert {
    condition     = jsondecode(aws_iam_role.ci["ci-plan-uat"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repository_id:12345:environment:infra-plan-uat"
    error_message = "Subject observado deve ser preservado integralmente."
  }
}
run "reject_subject_wildcard" {
  command = plan
  variables { verified_subjects = { ci-plan-uat = "repo:*" } }
  expect_failures = [var.verified_subjects]
}
run "exact_subject_and_scope" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role.ci["ci-plan-uat"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:test-only/infra:environment:infra-plan-uat"
    error_message = "Trust não pode aceitar repo/ref wildcard."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.state["ci-plan-uat"].policy).Statement[1].Resource == "arn:aws:s3:::test-only-state/uat/terraform.tfstate" && jsondecode(aws_iam_role_policy.state["ci-plan-uat"].policy).Statement[2].Resource == "arn:aws:s3:::test-only-state/uat/terraform.tfstate.tflock"
    error_message = "State e lock devem ficar apenas no scope UAT."
  }
}
