variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "uat", "prod"], var.env)
    error_message = "Ambiente inválido."
  }
}
variable "az_names" {
  type = list(string)
  validation {
    condition     = length(var.az_names) >= (var.env == "dev" ? 1 : 2) && length(distinct(var.az_names)) == length(var.az_names) && alltrue([for az in var.az_names : can(regex("^sa-east-1[a-z]$", az))])
    error_message = "Informar AZs distintas em sa-east-1: uma para Dev, duas para UAT/Prod."
  }
}
locals {
  octet  = { dev = 10, uat = 20, prod = 30 }[var.env]
  azs    = var.env == "dev" ? slice(var.az_names, 0, 1) : slice(var.az_names, 0, 2)
  groups = var.env == "dev" ? toset(["dev-box"]) : toset(["alb", "frontend", "api", "workers", "jobs", "rds", "cache"])
  ingress = var.env == "dev" ? {} : {
    frontend_alb  = { target = "frontend", source = "alb", port = 3000 }
    api_alb       = { target = "api", source = "alb", port = 8000 }
    api_frontend  = { target = "api", source = "frontend", port = 8000 }
    rds_api       = { target = "rds", source = "api", port = 5432 }
    rds_workers   = { target = "rds", source = "workers", port = 5432 }
    rds_jobs      = { target = "rds", source = "jobs", port = 5432 }
    cache_api     = { target = "cache", source = "api", port = 6379 }
    cache_workers = { target = "cache", source = "workers", port = 6379 }
    cache_jobs    = { target = "cache", source = "jobs", port = 6379 }
  }
}
resource "aws_vpc" "this" {
  cidr_block           = "10.${local.octet}.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "chico-${var.env}" }
  lifecycle { prevent_destroy = true }
}
resource "aws_default_security_group" "closed" {
  vpc_id = aws_vpc.this.id
  # Explicitly revoke AWS's default self ingress and allow-all egress.
}
resource "aws_internet_gateway" "this" { vpc_id = aws_vpc.this.id }
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.${local.octet}.${count.index}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
}
resource "aws_subnet" "data" {
  count             = var.env == "dev" ? 0 : length(local.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.${local.octet}.${20 + count.index}.0/24"
  availability_zone = local.azs[count.index]
}
resource "aws_route_table" "public" { vpc_id = aws_vpc.this.id }
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  route  = []
}
resource "aws_route_table_association" "data" {
  count          = length(aws_subnet.data)
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}
resource "aws_vpc_endpoint" "s3" {
  count             = var.env == "dev" ? 0 : 1
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.sa-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
}
resource "aws_security_group" "this" {
  for_each    = local.groups
  name        = "chico-${var.env}-${each.key}"
  description = "${each.key} ${var.env}; ingress explicit only"
  vpc_id      = aws_vpc.this.id
}
resource "aws_vpc_security_group_ingress_rule" "internal" {
  description                  = "${each.value.source} to ${each.value.target} in ${var.env}"
  for_each                     = local.ingress
  security_group_id            = aws_security_group.this[each.value.target].id
  referenced_security_group_id = aws_security_group.this[each.value.source].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}
resource "aws_vpc_security_group_ingress_rule" "web" {
  description       = "Public ${each.key} to edge only in ${var.env}"
  for_each          = { http = 80, https = 443 }
  security_group_id = aws_security_group.this[var.env == "dev" ? "dev-box" : "alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}
resource "aws_vpc_security_group_egress_rule" "compute" {
  description       = "Provider and AWS egress without NAT for ${each.key}"
  for_each          = var.env == "dev" ? toset(["dev-box"]) : toset(["api", "frontend", "workers", "jobs"])
  security_group_id = aws_security_group.this[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "alb" {
  description                  = "ALB to ${each.key} application port only"
  for_each                     = var.env == "dev" ? {} : { api = 8000, frontend = 3000 }
  security_group_id            = aws_security_group.this["alb"].id
  referenced_security_group_id = aws_security_group.this[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}
output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "data_subnet_ids" { value = aws_subnet.data[*].id }
output "security_group_ids" { value = { for k, v in aws_security_group.this : k => v.id } }
output "worker_rds_az" { value = local.azs[0] }
