mock_provider "aws" {}
variables {
  env      = "uat"
  az_names = ["sa-east-1a", "sa-east-1b"]
}
run "uat_private_data" {
  command = plan
  assert {
    condition     = aws_vpc.this.cidr_block == "10.20.0.0/16" && length(aws_subnet.data) == 2
    error_message = "UAT precisa de rede/dados separados em duas AZs."
  }
  assert {
    condition     = length(aws_route_table.data.route) == 0
    error_message = "Dados não podem ter rota à internet."
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.internal : r.cidr_ipv4 == null])
    error_message = "Ingressos de aplicação/dados devem referenciar SGs."
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.web : contains([80, 443], r.from_port)]) && length(aws_vpc_security_group_ingress_rule.web) == 2
    error_message = "Só HTTP/HTTPS entram da internet."
  }
}
run "prod_isolated" {
  command = plan
  variables { env = "prod" }
  assert {
    condition     = aws_vpc.this.cidr_block == "10.30.0.0/16" && length(aws_subnet.data) == 2
    error_message = "Prod deve ter CIDR próprio."
  }
}
run "dev_single_az" {
  command = plan
  variables { env = "dev" }
  assert {
    condition     = aws_vpc.this.cidr_block == "10.10.0.0/16" && length(aws_subnet.public) == 1 && length(aws_subnet.data) == 0 && length(aws_vpc_endpoint.s3) == 0
    error_message = "Dev usa uma AZ e Postgres/Redis locais."
  }
}
