mock_provider "aws" {
  override_during = plan
  mock_data "aws_ami" {
    defaults = { architecture = "x86_64", state = "available", name = "al2023-ami-synthetic-only", product_codes = [] }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.10.0.0/16", tags = { project = "chicoai", env = "dev" } }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-synthetic" }
  }
}
variables {
  ami_id                = "ami-synthetic"
  vpc_id                = "vpc-synthetic"
  subnet_id             = "subnet-synthetic"
  instance_profile_name = "chico-dev-restore"
  not_before_utc        = "2026-01-01T00:00:00Z"
  expires_at_utc        = "2026-01-03T00:00:00Z"
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_instance.stage) == 0 && length(aws_security_group.stage) == 0 && length(data.aws_ami.selected) == 0
    error_message = "Preparação do código não pode iniciar staging pago ou descobrir AMI implicitamente."
  }
}
run "bounded_isolated_temporary_host" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = aws_instance.stage[0].instance_type == "t3.medium" && aws_instance.stage[0].credit_specification[0].cpu_credits == "standard" && aws_instance.stage[0].root_block_device[0].volume_size == 160 && aws_instance.stage[0].root_block_device[0].encrypted && aws_instance.stage[0].root_block_device[0].volume_type == "gp3"
    error_message = "Capacidade temporária aprovada é t3.medium Standard e 160 GiB gp3 criptografados."
  }
  assert {
    condition     = aws_instance.stage[0].metadata_options[0].http_tokens == "required" && aws_instance.stage[0].metadata_options[0].http_put_response_hop_limit == 1 && aws_instance.stage[0].iam_instance_profile == "chico-dev-restore" && aws_instance.stage[0].instance_initiated_shutdown_behavior == "stop"
    error_message = "SSM/profile separado, IMDSv2 e parada sem exclusão automática são obrigatórios."
  }
  assert {
    condition     = length(aws_security_group.stage[0].ingress) == 0 && aws_vpc_security_group_egress_rule.https[0].from_port == 443 && aws_vpc_security_group_egress_rule.https[0].to_port == 443 && aws_vpc_security_group_egress_rule.https[0].ip_protocol == "tcp"
    error_message = "Staging não publica portas; somente egress HTTPS explícito."
  }
  assert {
    condition     = aws_instance.stage[0].tags.env == "restore" && aws_instance.stage[0].volume_tags.env == "restore" && aws_security_group.stage[0].tags.env == "restore"
    error_message = "CI Dev não pode administrar host/volume/SG sensíveis temporários pelo grant project/env=dev."
  }
}
run "reject_runtime_profile_reuse" {
  command = plan
  variables {
    enabled               = true
    instance_profile_name = "chico-dev-runtime"
  }
  expect_failures = [var.instance_profile_name]
}
run "reject_foreign_subnet" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.aws_subnet.selected[0]
    values = { vpc_id = "vpc-foreign-synthetic" }
  }
  expect_failures = [aws_instance.stage[0]]
}
run "reject_arm_image_for_x86_conversion_host" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.aws_ami.selected[0]
    values = { architecture = "arm64", state = "available", name = "al2023-ami-synthetic-only", product_codes = [] }
  }
  expect_failures = [aws_instance.stage[0]]
}
run "reject_extended_lease" {
  command = plan
  variables { expires_at_utc = "2026-01-03T00:00:01Z" }
  expect_failures = [var.expires_at_utc]
}
