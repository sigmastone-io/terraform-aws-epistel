output "hostname" {
  description = "What to enter in a mail client: this name, port 993 for incoming and 465 for outgoing, both SSL/TLS."
  value       = lower(var.hostname)
}

output "public_ip" {
  value = module.compute.public_ip
}

output "instance_id" {
  value = module.compute.instance_id
}

output "bucket" {
  value = module.storage.bucket_name
}

output "table" {
  value = module.storage.table_name
}

output "queue_url" {
  value = module.ses_inbound.queue_url
}

output "dead_letter_queue_url" {
  value = module.ses_inbound.dead_letter_queue_url
}

output "log_group" {
  value = module.compute.log_group
}

output "repository_url" {
  description = "The repository to push the image to, when this module made it."
  value       = var.ecr.create ? aws_ecr_repository.own[0].repository_url : null
}

output "recipients" {
  description = "Every address the receipt rule accepts mail for."
  value       = local.recipients
}

output "session_command" {
  description = "Opens a shell on the instance. Needs the Session Manager plugin for the AWS CLI."
  value       = "aws ssm start-session --region ${data.aws_region.current.region} --target ${module.compute.instance_id}"
}

output "password_commands" {
  description = <<-EOT
    How a mailbox gets a password. Open a shell with `session_command`, then run the command for
    the mailbox. It prints an app password once; enter it in the mail client. Run it again for
    every further device. Passwords never pass through Terraform or its state.
  EOT
  value = {
    for mailbox in var.mailboxes :
    lower(mailbox.address) => "sudo docker exec epistel epistel password new ${lower(mailbox.address)} --label <device>"
  }
}
