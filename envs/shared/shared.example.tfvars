# Proposed bucket names; existence/availability and cost are not confirmed.
account_id                              = "306915830875"
owner                                   = "Felipe"
cost_center                             = "Chico-IA"
provision_enabled                       = false
foundation_enabled                      = false # explicitly enable only for reviewed initial shared wave
review_bucket_name                      = null  # reconciled unique chico-infra-review-* bucket
review_access_log_bucket_name           = null  # dedicated source-scoped access sink
credit_approval                         = null
audit_bucket_name                       = "chico-audit-306915830875-sa-east-1"
audit_access_log_bucket_name            = "chico-audit-access-306915830875-sa-east-1"
access_log_retention_days               = 30
audit_kms_key_arn                       = null  # actual reviewed key and service policies required
oidc_provider_arn                       = null  # actual issuer ARN required; no provider found yet
state_bucket_arn                        = null  # actual bootstrap output required
alert_emails                            = []    # private confirmed destination, never example approval
budget_limits                           = {}    # complete account/shared/dev/uat/prod from covered quote
dev_ci_policy_documents                 = null  # generated only after real metadata reconciliation
activate_environment_cost_tag           = false # enable only after real env tag is visible in Cost Explorer
environment_cost_tag_evidence_reference = null
oidc_bindings = {
  ci-plan-dev        = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-plan-dev", writable_state = false }
  ci-infra-apply-dev = { scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra", environment = "infra-apply-dev", writable_state = true }
}
