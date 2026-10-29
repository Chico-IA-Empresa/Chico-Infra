variable "ami_id" {
  description = "ARM64 AMI verified in sa-east-1, with SSM agent; never guess image IDs."
  type        = string
}
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "instance_profile_name" { type = string }
variable "bootstrap_user_data" {
  description = "Reviewed nonsecret OS/bootstrap script; application deploy remains a separate SSM step."
  type        = string
  default     = null
}
variable "compose_version" { type = string }
variable "root_volume_size_gib" {
  description = "Explicitly reviewed capacity; phase 1 approved proposal uses 80 GiB after backup sizing."
  type        = number
  default     = 30
  validation {
    condition     = var.root_volume_size_gib >= 30 && var.root_volume_size_gib <= 80 && floor(var.root_volume_size_gib) == var.root_volume_size_gib
    error_message = "Capacidade gp3 inteira de 30 a 80 GiB; delta maior exige revisão do contrato."
  }
}
variable "compose_sha256" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.compose_sha256))
    error_message = "Checksum ARM64 revisado do release Docker Compose obrigatório."
  }
}
data "aws_ami" "selected" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}
locals {
  bootstrap = join("\n", [
    "#!/bin/bash",
    "export COMPOSE_VERSION='${var.compose_version}'",
    "export COMPOSE_SHA256='${var.compose_sha256}'",
    file("${path.module}/bootstrap-lib.sh"),
    file("${path.module}/bootstrap.sh"),
    "install -d -m 0700 /usr/local/lib/chico",
    "cat > /usr/local/lib/chico/proxy-events.py <<'CHICO_PROXY_EVENTS'",
    file("${path.module}/proxy-events.py"),
    "CHICO_PROXY_EVENTS",
    "cat > /usr/local/lib/chico/proxy-logs.sh <<'CHICO_PROXY_LOGS'",
    file("${path.module}/proxy-logs.sh"),
    "CHICO_PROXY_LOGS",
    "cat > /usr/local/sbin/chico-dev-metrics <<'CHICO_METRICS'",
    file("${path.module}/metrics.sh"),
    "CHICO_METRICS",
    "cat > /usr/local/sbin/chico-dev-logs <<'CHICO_LOGS'",
    file("${path.module}/logs.sh"),
    "CHICO_LOGS",
    "chmod 0700 /usr/local/sbin/chico-dev-metrics /usr/local/sbin/chico-dev-logs",
    file("${path.module}/metrics-units.sh")
  ])
}
resource "aws_instance" "this" {
  ebs_optimized = true
  ami           = var.ami_id
  instance_type = "t4g.small"
  credit_specification {
    cpu_credits = "standard"
  }
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  user_data                   = coalesce(var.bootstrap_user_data, local.bootstrap)
  # A reviewed user-data repair stops/starts this same instance. Preserve the
  # retained root volume; an explicit SSM replay verifies the repaired script.
  user_data_replace_on_change = false
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    delete_on_termination = false
  }
  monitoring  = false
  tags        = { Name = "chico-dev" }
  volume_tags = { project = "chicoai", env = "dev" }
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.aws_ami.selected.architecture == "arm64" && data.aws_ami.selected.state == "available" && startswith(data.aws_ami.selected.name, "al2023-ami-")
      error_message = "AMI Amazon Linux 2023 ARM64 disponível exigida pelo bootstrap."
    }
    precondition {
      condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.compose_version))
      error_message = "Fixar release Compose sem latest."
    }
  }
}
resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id
  lifecycle { prevent_destroy = true }
}
output "instance_id" { value = aws_instance.this.id }
output "allocation_id" { value = aws_eip.this.allocation_id }
output "public_ip" { value = aws_eip.this.public_ip }
output "root_volume_id" { value = one(aws_instance.this.root_block_device).volume_id }
output "mount_contract" {
  value = { root = "/srv/chico", postgres = "/srv/chico/postgres", redis = "/srv/chico/redis", files = "/srv/chico/files", tls = "/srv/chico/tls", fixture = "/srv/chico/fixture", strategy = "retained-root-volume; snapshot/restore before replacement; no automatic formatting" }
}
