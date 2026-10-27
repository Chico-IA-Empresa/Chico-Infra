variable "compute_enabled" {
  type    = bool
  default = false
}
variable "root_volume_size_gib" {
  description = "Reviewed disk capacity; measure backup expansion before enabling compute."
  type        = number
  default     = 30
}
variable "ami_id" {
  type    = string
  default = null
}
variable "compose_version" {
  type    = string
  default = null
}
variable "compose_sha256" {
  type    = string
  default = null
}
module "dev_box" {
  count                 = var.provision_enabled && var.compute_enabled ? 1 : 0
  source                = "../../modules/dev-box"
  ami_id                = var.ami_id
  subnet_id             = module.network[0].public_subnet_ids[0]
  security_group_id     = module.network[0].security_group_ids["dev-box"]
  instance_profile_name = aws_iam_instance_profile.runtime[0].name
  compose_version       = var.compose_version
  compose_sha256        = var.compose_sha256
  root_volume_size_gib  = var.root_volume_size_gib
  depends_on            = [module.funding]
}
