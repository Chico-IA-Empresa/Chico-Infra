locals {
  host_enabled = var.provision_enabled && var.compute_enabled
}
variable "repository_arns" {
  description = "Explicit shared outputs after ownership reconciliation; no remote state access."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.repository_arns : can(regex("^arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-(api|workers|frontend)$", a))])
    error_message = "Somente os três repos compartilhados na conta aprovada."
  }
}
resource "aws_iam_role" "runtime" {
  count                = local.host_enabled ? 1 : 0
  name                 = "chico-dev-runtime"
  path                 = "/chico/dev/"
  permissions_boundary = var.permissions_boundary_arns == null ? null : var.permissions_boundary_arns.runtime
  assume_role_policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  lifecycle {
    precondition {
      condition     = length(var.repository_arns) == 3
      error_message = "Conferir e fornecer os três ARNs ECR shared antes do host."
    }
    precondition {
      condition     = var.permissions_boundary_arns != null
      error_message = "Provisionar/reconciliar boundaries shared antes de permitir mutação IAM pelo CI Dev."
    }
  }
  depends_on = [module.funding]
}
resource "aws_iam_instance_profile" "runtime" {
  count = local.host_enabled ? 1 : 0
  name  = "chico-dev-runtime"
  path  = "/chico/dev/"
  role  = aws_iam_role.runtime[0].name
}
resource "aws_iam_role_policy" "ssm_agent" {
  count = local.host_enabled ? 1 : 0
  role  = aws_iam_role.runtime[0].id
  # SSM core agent actions, intentionally excluding managed-policy wildcard
  # GetParameter/GetParameters. Configuration gets a separate exact-ARN grant.
  # These agent/channel APIs retain the managed policy's Resource=* pattern.
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Sid       = "AgentCore"
      Effect    = "Allow"
      Action    = ["ssm:DescribeAssociation", "ssm:GetDeployablePatchSnapshotForInstance", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:GetManifest", "ssm:ListAssociations", "ssm:ListInstanceAssociations", "ssm:PutInventory", "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult", "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus", "ssm:UpdateInstanceInformation"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } }
    },
    {
      Sid       = "SessionChannels"
      Effect    = "Allow"
      Action    = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } }
    },
    {
      Sid       = "LegacyAgentChannels"
      Effect    = "Allow"
      Action    = ["ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage", "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } }
    }
  ] })
}
resource "aws_iam_role_policy" "pull" {
  count = local.host_enabled ? 1 : 0
  role  = aws_iam_role.runtime[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = sort(tolist(var.repository_arns)) }
  ] })
}
variable "permissions_boundary_arns" {
  type    = object({ runtime = string, flow = string })
  default = null
  validation {
    condition = var.permissions_boundary_arns == null ? true : (
      var.permissions_boundary_arns.runtime == "arn:aws:iam::${var.account_id}:policy/chico/shared/chico-dev-runtime-boundary" &&
      var.permissions_boundary_arns.flow == "arn:aws:iam::${var.account_id}:policy/chico/shared/chico-dev-flow-boundary"
    )
    error_message = "Boundaries Dev exatas da root shared são obrigatórias."
  }
}
