mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-fixture" } }
}
variables {
  ami_id                = "ami-0123456789abcdef0"
  subnet_id             = "subnet-fixture"
  security_group_id     = "sg-fixture"
  instance_profile_name = "synthetic-runtime"
  compose_version       = "v5.6.0"
  compose_sha256        = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
run "host_safety" {
  command = plan
  assert {
    condition     = length(local.bootstrap) <= 16384
    error_message = "Bootstrap deve caber no limite de user data EC2; não truncar scripts de observabilidade."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t4g.small" && aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1 && !aws_instance.this.associate_public_ip_address
    error_message = "ARM64 small sem IP efêmero e metadata restrita."
  }
  assert {
    condition     = one(aws_instance.this.root_block_device).encrypted && !one(aws_instance.this.root_block_device).delete_on_termination && one(aws_instance.this.root_block_device).volume_size == 30
    error_message = "Baseline de dados deve ser criptografado e retido."
  }
}
run "wrong_architecture" {
  command = plan
  override_data {
    target = data.aws_ami.selected
    values = { architecture = "x86_64", state = "available", name = "al2023-ami-fixture" }
  }
  expect_failures = [aws_instance.this]
}
run "invalid_checksum" {
  command = plan
  variables { compose_sha256 = "unverified" }
  expect_failures = [var.compose_sha256]
}
