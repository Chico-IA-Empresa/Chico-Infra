variable "enabled" {
  type    = bool
  default = false
}
variable "ami_id" {
  type    = string
  default = null
}
variable "vpc_id" {
  type    = string
  default = null
}
variable "subnet_id" {
  type    = string
  default = null
}
variable "instance_profile_name" {
  type    = string
  default = null
  validation {
    condition     = !var.enabled || var.instance_profile_name == "chico-dev-restore"
    error_message = "Staging usa somente o profile temporário separado de restore."
  }
}
variable "not_before_utc" { type = string }
variable "expires_at_utc" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.expires_at_utc)) && try(timecmp(var.expires_at_utc, var.not_before_utc) > 0 && timecmp(var.expires_at_utc, timeadd(var.not_before_utc, "48h")) <= 0, false)
    error_message = "Janela UTC explícita de no máximo 48h, compartilhada com o lease IAM."
  }
}
data "aws_ami" "selected" {
  count  = var.enabled ? 1 : 0
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}
data "aws_vpc" "selected" {
  count = var.enabled ? 1 : 0
  id    = var.vpc_id
}
data "aws_subnet" "selected" {
  count = var.enabled ? 1 : 0
  id    = var.subnet_id
}
locals {
  # Keep the temporary host outside CI's project=chicoai/env=dev write scope.
  # Account-wide gross budget includes it; reconcile temporary costs separately.
  stage_tags = { project = "chicoai", env = "restore", purpose = "dev-restore", Name = "chico-dev-restore-stage", "expires-at-utc" = var.expires_at_utc }
}
resource "aws_security_group" "stage" {
  count       = var.enabled ? 1 : 0
  name        = "chico-dev-restore-stage"
  description = "Temporary restore: no ingress, HTTPS egress only; database stays network-isolated"
  vpc_id      = var.vpc_id
  ingress     = []
  tags        = local.stage_tags
}
resource "aws_vpc_security_group_egress_rule" "https" {
  count             = var.enabled ? 1 : 0
  security_group_id = aws_security_group.stage[0].id
  description       = "AWS SSM/S3 and reviewed package/image endpoints over TLS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = local.stage_tags
}
resource "aws_instance" "stage" {
  count                       = var.enabled ? 1 : 0
  ami                         = var.ami_id
  instance_type               = "t3.medium"
  ebs_optimized               = true
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.stage[0].id]
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = true
  # Expiry stops compute and retains data. Only an explicitly reviewed cleanup
  # termination deletes this temporary root volume after recovery is proven.
  instance_initiated_shutdown_behavior = "stop"
  user_data = join("\n", [
    "#!/bin/bash",
    "export CHICO_STAGE_EXPIRES_UTC='${var.expires_at_utc}'",
    file("${path.module}/bootstrap.sh")
  ])
  user_data_replace_on_change = true
  credit_specification { cpu_credits = "standard" }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 160
    delete_on_termination = true
  }
  monitoring  = false
  tags        = local.stage_tags
  volume_tags = local.stage_tags
  depends_on  = [aws_vpc_security_group_egress_rule.https]
  lifecycle {
    precondition {
      condition     = data.aws_ami.selected[0].architecture == "x86_64" && data.aws_ami.selected[0].state == "available" && startswith(data.aws_ami.selected[0].name, "al2023-ami-") && length(data.aws_ami.selected[0].product_codes) == 0
      error_message = "AMI Amazon AL2023 x86_64 disponível, sem Marketplace, revisada obrigatória."
    }
    precondition {
      condition     = data.aws_subnet.selected[0].vpc_id == var.vpc_id && data.aws_vpc.selected[0].cidr_block == "10.10.0.0/16" && try(data.aws_vpc.selected[0].tags.project == "chicoai" && data.aws_vpc.selected[0].tags.env == "dev", false)
      error_message = "Subnet e VPC Dev reais e reconciliados obrigatórios; não reutilizar VPC default/legada."
    }
  }
}
output "host" {
  value = var.enabled ? {
    instance_id       = aws_instance.stage[0].id, volume_id = aws_instance.stage[0].root_block_device[0].volume_id,
    security_group_id = aws_security_group.stage[0].id, expires_at_utc = var.expires_at_utc,
    shutdown_behavior = "stop", volume_deleted_only_on_reviewed_termination = true
  } : null
}
