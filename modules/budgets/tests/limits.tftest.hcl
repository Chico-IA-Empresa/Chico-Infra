mock_provider "aws" {}
variables {
  alert_emails = ["synthetic@example.invalid"]
  # Unit-test-only envelopes, not an approved financial review.
  limits = { account = 1000, shared = 1, dev = 1, uat = 60, prod = 1 }
}
run "complete_scope_coverage" {
  command = plan
  assert {
    condition     = length(aws_budgets_budget.this) == 5 && aws_budgets_budget.this["dev"].cost_types[0].include_credit == false && aws_budgets_budget.this["account"].cost_types[0].include_tax && length(aws_budgets_budget.this["dev"].notification) == 2
    error_message = "Consumo bruto deve cobrir conta e todos os scopes, incluindo impostos, sem créditos, com dois alertas."
  }
}
run "reject_missing_account_and_dev" {
  command = plan
  variables { limits = { uat = 60 } }
  expect_failures = [var.limits]
}
run "reject_foreign_scope" {
  command = plan
  variables { limits = { account = 1000, shared = 1, dev = 1, uat = 60, prod = 1, other = 1 } }
  expect_failures = [var.limits]
}
