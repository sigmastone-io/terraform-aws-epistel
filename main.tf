# Epistel on AWS: the storage, the path from SES to the server, and the server itself.
#
# What this module makes is its own: a bucket, a table, a topic, two queues, one receipt rule,
# one instance with its address, role and certificate. What already exists is named, not made:
# the SES identities, the receipt rule set, the DNS zone, the image, and the addresses mail is
# received for.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # Every address mail is accepted for: each mailbox's own, and its aliases.
  recipients = distinct(flatten([for mailbox in var.mailboxes : concat([mailbox.address], mailbox.aliases)]))

  ses_identity_arns = [
    for identity in var.ses_identities :
    "arn:${data.aws_partition.current.partition}:ses:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:identity/${identity}"
  ]

  rule_set_name = var.receipt.create_rule_set ? aws_ses_receipt_rule_set.own[0].rule_set_name : var.receipt.rule_set_name

  repository_arn = var.ecr.create ? aws_ecr_repository.own[0].arn : var.ecr.repository_arn

  # The server's configuration file. Strings are written the way JSON writes them, which TOML
  # reads the same way.
  config = join("\n", concat(
    [
      "[server]",
      "hostname = ${jsonencode(lower(var.hostname))}",
      "",
      "[tls]",
      "certificate = \"/etc/epistel/tls/fullchain.pem\"",
      "private_key = \"/etc/epistel/tls/key.pem\"",
      "",
      "[imap]",
      "listen = \"0.0.0.0:993\"",
      "",
      "[submission]",
      "listen = \"0.0.0.0:465\"",
      "max_message_size = ${jsonencode(var.max_message_size)}",
      "",
      "[metadata]",
      "backend = \"dynamodb\"",
      "table = ${jsonencode(module.storage.table_name)}",
      "region = ${jsonencode(data.aws_region.current.region)}",
      "",
      "[blobs]",
      "backend = \"s3\"",
      "bucket = ${jsonencode(module.storage.bucket_name)}",
      "prefix = \"blobs/\"",
      "region = ${jsonencode(data.aws_region.current.region)}",
      "",
      "[inbound]",
      "backend = \"ses-sqs\"",
      "queue_url = ${jsonencode(module.ses_inbound.queue_url)}",
      "region = ${jsonencode(data.aws_region.current.region)}",
      "",
      "[outbound]",
      "backend = \"ses\"",
      "region = ${jsonencode(data.aws_region.current.region)}",
    ],
    flatten([
      for mailbox in var.mailboxes : [
        "",
        "[[mailbox]]",
        "address = ${jsonencode(lower(mailbox.address))}",
        "name = ${jsonencode(mailbox.name)}",
        "aliases = ${jsonencode([for alias in mailbox.aliases : lower(alias)])}",
      ]
    ]),
  ))
}

# Only for an account that receives no mail yet. An account that does has an active rule set,
# and activating another one switches every existing rule off.
resource "aws_ses_receipt_rule_set" "own" {
  count         = var.receipt.create_rule_set ? 1 : 0
  rule_set_name = var.receipt.rule_set_name
}

resource "aws_ses_active_receipt_rule_set" "own" {
  count         = var.receipt.create_rule_set ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.own[0].rule_set_name
}

# Only when no repository exists to point at.
resource "aws_ecr_repository" "own" {
  count                = var.ecr.create ? 1 : 0
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

module "storage" {
  source = "./modules/storage"

  name                  = var.name
  bucket_name           = var.bucket_name
  receipt_rule_set_name = local.rule_set_name
  protect               = var.protect_data
}

module "ses_inbound" {
  source = "./modules/ses-inbound"

  name          = var.name
  rule_set_name = local.rule_set_name
  after_rule    = var.receipt.after_rule
  tls_policy    = var.receipt.tls_policy
  recipients    = local.recipients
  bucket_name   = module.storage.bucket_name
  alarm_actions = var.alarm_actions

  # SES checks that it may write to the bucket when the rule is created.
  depends_on = [module.storage]
}

module "compute" {
  source = "./modules/compute-ec2"

  name               = var.name
  hostname           = var.hostname
  image              = var.image
  config             = local.config
  instance_type      = var.instance_type
  subnet_id          = var.network.subnet_id
  network_cidr       = var.network.cidr
  allowed_cidrs      = var.allowed_cidrs
  zone_id            = var.zone_id
  acme               = var.acme
  bucket_name        = module.storage.bucket_name
  bucket_arn         = module.storage.bucket_arn
  table_arn          = module.storage.table_arn
  queue_arn          = module.ses_inbound.queue_arn
  ses_identity_arns  = local.ses_identity_arns
  ecr_repository_arn = local.repository_arn
  log_retention_days = var.log_retention_days
}
