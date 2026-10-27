provider "aws" {
  region              = "sa-east-1"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { project = "chicoai", env = "shared", owner = var.owner, "cost-center" = var.cost_center, "managed-by" = "terraform" }
  }
}
module "funding" {
  source     = "../../modules/funding"
  enabled    = var.provision_enabled
  account_id = var.account_id
  approval   = var.credit_approval
}
