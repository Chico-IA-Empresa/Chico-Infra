resource "aws_cloudwatch_log_group" "flow" {
  count             = local.host_enabled ? 1 : 0
  name              = "/chico/dev/flow"
  retention_in_days = 30
  kms_key_id        = var.logs_key_arn
  depends_on        = [module.funding]
}
resource "aws_iam_role" "flow" {
  count                = local.host_enabled ? 1 : 0
  name                 = "chico-dev-flow-logs"
  path                 = "/chico/dev/"
  permissions_boundary = var.permissions_boundary_arns == null ? null : var.permissions_boundary_arns.flow
  assume_role_policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ec2:sa-east-1:${var.account_id}:vpc-flow-log/*" } } }] })
  depends_on           = [module.funding]
}
resource "aws_iam_role_policy" "flow" {
  count = local.host_enabled ? 1 : 0
  role  = aws_iam_role.flow[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.flow[0].arn}:*" },
    { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" }
  ] })
}
resource "aws_flow_log" "dev" {
  count                    = local.host_enabled ? 1 : 0
  vpc_id                   = module.network[0].vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn             = aws_iam_role.flow[0].arn
  max_aggregation_interval = 600
  depends_on               = [aws_iam_role_policy.flow]
}
