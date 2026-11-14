# SPDX-FileCopyrightText: 2026 Sigmastone OÜ
# SPDX-License-Identifier: Apache-2.0

# A deployment of the module, driven by one file.
#
# Copy `config.example.yaml` to `config.yaml`, fill it in, and run Terraform here:
#
#   terraform init
#   terraform plan
#   terraform apply
#
# `config.yaml` and the state file stay on this machine; git ignores both. Nothing in this
# directory names any particular deployment.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  # The state in a file beside this one. Move it to a shared backend when more than one person
  # applies.
  backend "local" {}
}

locals {
  config = yamldecode(file("${path.module}/config.yaml"))
}

provider "aws" {
  region  = local.config.region
  profile = try(local.config.profile, null)

  default_tags {
    tags = try(local.config.tags, {})
  }
}

# The zone is pointed at by name; its identifier is looked up.
data "aws_route53_zone" "mail" {
  name         = local.config.dns_zone
  private_zone = false
}

module "epistel" {
  source = "../"

  name           = try(local.config.name, "epistel")
  hostname       = local.config.hostname
  mailboxes      = local.config.mailboxes
  image          = local.config.image
  ecr            = try(local.config.ecr, {})
  ses_identities = local.config.ses_identities
  receipt        = local.config.receipt
  zone_id        = data.aws_route53_zone.mail.zone_id
  acme           = local.config.acme
  network        = try(local.config.network, {})
  allowed_cidrs  = try(local.config.allowed_cidrs, ["0.0.0.0/0"])
  instance_type  = try(local.config.instance_type, "t3.micro")
  protect_data   = try(local.config.protect_data, true)
}

output "hostname" {
  value = module.epistel.hostname
}

output "public_ip" {
  value = module.epistel.public_ip
}

output "repository_url" {
  value = module.epistel.repository_url
}

output "recipients" {
  value = module.epistel.recipients
}

output "session_command" {
  value = module.epistel.session_command
}

output "password_commands" {
  value = module.epistel.password_commands
}

output "log_group" {
  value = module.epistel.log_group
}

output "dead_letter_queue_url" {
  value = module.epistel.dead_letter_queue_url
}
