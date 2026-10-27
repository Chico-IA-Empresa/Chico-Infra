variable "alert_emails" {
  type = set(string)
  validation {
    condition     = length(var.alert_emails) > 0 && alltrue([for e in var.alert_emails : can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", e))])
    error_message = "Destinatário real necessário. Não publicar endereço no Trello."
  }
}
variable "limits" {
  type = map(number)
  validation {
    condition     = toset(keys(var.limits)) == toset(["account", "shared", "dev", "uat", "prod"]) && alltrue([for v in values(var.limits) : v > 0]) && try(var.limits["uat"] == 60, false)
    error_message = "Informar os cinco limites positivos account/shared/dev/uat/prod; UAT 60 USD. Total é consumo bruto, não autorização de pagamento."
  }
}
resource "aws_budgets_budget" "this" {
  for_each     = var.limits
  name         = "chico-${each.key}-gross"
  budget_type  = "COST"
  limit_amount = tostring(each.value)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_types {
    include_credit             = false
    include_refund             = false
    include_tax                = true
    include_subscription       = true
    include_support            = true
    include_upfront            = true
    include_recurring          = true
    include_other_subscription = true
    use_blended                = false
  }
  dynamic "cost_filter" {
    # One CostFilters map entry per name. A second TagKeyValue block would
    # overwrite the first in the AWS request. Unique project environment tag
    # is reviewed with the account's other projects before provisioning.
    for_each = each.key == "account" ? {} : { env = each.key }
    content {
      name   = "TagKeyValue"
      values = [format("user:%s$%s", cost_filter.key, cost_filter.value)]
    }
  }
  dynamic "notification" {
    for_each = toset([80, 100])
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.alert_emails
    }
  }
}
