mock_provider "aws" {}
variables {
  provider_arn     = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_arn = "arn:aws:s3:::synthetic-state-only"
  bindings = {
    ci-build-dev  = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
    ci-deploy-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = false }
  }
}
run "proof_roles_exact_audience_subject_and_no_state_grant" {
  command = plan
  assert {
    condition = length(aws_iam_role.ci) == 2 && length(aws_iam_role_policy.state) == 0 && alltrue([
      for role in aws_iam_role.ci : jsondecode(role.assume_role_policy).Statement[0] == jsondecode(jsonencode({
        Effect    = "Allow"
        Principal = { Federated = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = { StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:Chico-IA-Empresa/Chico-Infra:environment:infra-apply-dev"
        } }
      }))
    ])
    error_message = "Proof identities must have only the exact protected Environment trust and zero state/lock policies."
  }
}
run "proof_roles_reject_state_read_access" {
  command = plan
  variables {
    bindings = {
      ci-build-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = false, state_access = true }
    }
  }
  expect_failures = [var.bindings]
}
run "proof_roles_reject_state_write_without_access" {
  command = plan
  variables {
    bindings = {
      ci-deploy-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = true, state_access = false }
    }
  }
  expect_failures = [var.bindings]
}
