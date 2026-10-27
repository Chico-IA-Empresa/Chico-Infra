variables {
  enabled    = true
  account_id = "123456789012"
}
run "reject_missing_evidence" {
  command         = plan
  expect_failures = [terraform_data.gate]
}
run "disabled_is_safe" {
  command = plan
  variables { enabled = false }
}
run "reject_expired" {
  command = plan
  variables {
    approval = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2020-01-01", expires_on = "2020-01-02", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  expect_failures = [terraform_data.gate]
}
run "reject_wrong_account_or_uncovered_charge" {
  command = plan
  variables {
    approval = { account_id = "999999999999", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = false, shutdown_reserve_confirmed = true }
  }
  expect_failures = [terraform_data.gate]
}
