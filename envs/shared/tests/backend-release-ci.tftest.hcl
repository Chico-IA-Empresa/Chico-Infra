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
    ci-build-backend-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Back", environment = "release-dev", writable_state = false, state_access = false }
  }
  credit_approval = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
}

run "backend_release_disabled_by_default" {
  command = plan
  variables { provision_enabled = true }
  assert {
    condition     = length(aws_iam_policy.backend_release_ci) == 0 && length(aws_iam_role_policy_attachment.backend_release_ci) == 0 && output.backend_release_ci_review == null
    error_message = "Inputs Shared existentes não ganham a policy de publicação por padrão."
  }
}

run "backend_release_cannot_bypass_provision_gate" {
  command = plan
  variables { backend_release_ci = { review_reference = "synthetic-only" } }
  assert {
    condition     = length(aws_iam_policy.backend_release_ci) == 0 && length(aws_iam_role_policy_attachment.backend_release_ci) == 0
    error_message = "Opt-in não contorna provision_enabled."
  }
}

run "backend_release_exact_ecr_grant" {
  command = plan
  variables {
    provision_enabled  = true
    backend_release_ci = { review_reference = "synthetic-only" }
  }
  assert {
    condition     = length(aws_iam_policy.backend_release_ci) == 1 && aws_iam_role_policy_attachment.backend_release_ci[0].role == "ci-build-backend-dev" && length(aws_iam_policy.dev_proof_ci) == 0
    error_message = "Uma policy, presa à role do Chico-Back, sem mexer nos grants de prova."
  }
  assert {
    condition = jsondecode(aws_iam_policy.backend_release_ci[0].policy) == jsondecode(jsonencode({ Version = "2012-10-17", Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:DescribeImageScanFindings"], Resource = ["arn:aws:ecr:sa-east-1:123456789012:repository/chico-api", "arn:aws:ecr:sa-east-1:123456789012:repository/chico-workers"] },
      { Effect = "Allow", Action = ["ecr:GetRegistryScanningConfiguration"], Resource = "*" }
    ] }))
    error_message = "Só push/leitura em chico-api e chico-workers; frontend, state, SSM e ECS ficam fora."
  }
  assert {
    condition     = output.backend_release_ci_review.subject == "repo:Chico-IA-Empresa/Chico-Back:environment:release-dev" && !output.backend_release_ci_review.state_access
    error_message = "Subject exato do Environment release-dev do Chico-Back."
  }
}

run "backend_release_rejects_foreign_repository" {
  command = plan
  variables {
    provision_enabled  = true
    backend_release_ci = { review_reference = "synthetic-only" }
    oidc_bindings = {
      ci-build-backend-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Front", environment = "release-dev", writable_state = false, state_access = false }
    }
  }
  expect_failures = [aws_iam_policy.backend_release_ci[0]]
}

run "backend_release_rejects_wrong_environment" {
  command = plan
  variables {
    provision_enabled  = true
    backend_release_ci = { review_reference = "synthetic-only" }
    oidc_bindings = {
      ci-build-backend-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Back", environment = "infra-apply-dev", writable_state = false, state_access = false }
    }
  }
  expect_failures = [aws_iam_policy.backend_release_ci[0]]
}

run "backend_release_rejects_foreign_custom_subject" {
  command = plan
  variables {
    provision_enabled      = true
    backend_release_ci     = { review_reference = "synthetic-only" }
    verified_oidc_subjects = { ci-build-backend-dev = "repo:Chico-IA-Empresa/Chico-Back:ref:refs/heads/main" }
  }
  expect_failures = [aws_iam_policy.backend_release_ci[0]]
}

run "backend_release_rejects_missing_binding" {
  command = plan
  variables {
    provision_enabled  = true
    backend_release_ci = { review_reference = "synthetic-only" }
    oidc_bindings      = {}
  }
  expect_failures = [aws_iam_policy.backend_release_ci[0]]
}

run "backend_release_rejects_empty_review_reference" {
  command = plan
  variables {
    provision_enabled  = true
    backend_release_ci = { review_reference = " " }
  }
  expect_failures = [var.backend_release_ci]
}
