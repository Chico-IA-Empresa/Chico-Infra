output "network" {
  value = var.provision_enabled ? { vpc_id = module.network[0].vpc_id, subnet_ids = module.network[0].public_subnet_ids, security_group_ids = module.network[0].security_group_ids } : null
}
output "host" {
  value = local.host_enabled ? { instance_id = module.dev_box[0].instance_id, allocation_id = module.dev_box[0].allocation_id, public_ip = module.dev_box[0].public_ip, volume_id = module.dev_box[0].root_volume_id, mount_contract = module.dev_box[0].mount_contract, runtime_role_arn = aws_iam_role.runtime[0].arn, profile_arn = aws_iam_instance_profile.runtime[0].arn } : null
}
output "configuration" {
  value = var.provision_enabled ? { secret_arns = module.configuration[0].secret_arns } : null
}
