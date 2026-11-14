# SPDX-FileCopyrightText: 2026 Sigmastone OÜ
# SPDX-License-Identifier: Apache-2.0

# Where mail lives: one bucket for messages, one table for everything about them.
#
# The bucket has three prefixes. SES writes received mail under `incoming/`; the server moves it
# to `blobs/` when it files it; `state/` holds what the instance has to find again after it is
# replaced, which today is the certificate.

variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "bucket_name" {
  description = "Name of the bucket. Bucket names are global, so the default adds account and region."
  type        = string
  default     = null
}

variable "receipt_rule_set_name" {
  description = "The receipt rule set whose rule writes into the bucket. Only that rule set may."
  type        = string
}

variable "protect" {
  description = "Refuse to destroy the table and a bucket that still holds mail."
  type        = bool
  default     = true
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = coalesce(var.bucket_name, "${var.name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}")
}

resource "aws_s3_bucket" "mail" {
  bucket        = local.bucket_name
  force_destroy = !var.protect
}

resource "aws_s3_bucket_public_access_block" "mail" {
  bucket                  = aws_s3_bucket.mail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "mail" {
  bucket = aws_s3_bucket.mail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Encryption with keys S3 manages. A key of the deployer's own is on the roadmap; it costs a
# monthly fee and needs grants for SES and SNS, which the cheapest shape does without.
resource "aws_s3_bucket_server_side_encryption_configuration" "mail" {
  bucket = aws_s3_bucket.mail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A deleted or overwritten message can be brought back for a month.
resource "aws_s3_bucket_versioning" "mail" {
  bucket = aws_s3_bucket.mail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mail" {
  bucket     = aws_s3_bucket.mail.id
  depends_on = [aws_s3_bucket_versioning.mail]

  # The server removes a received message once it is filed. What is still here after two weeks
  # was never filed, and by then the queue has given up on it too.
  rule {
    id     = "expire-unfiled-incoming"
    status = "Enabled"

    filter {
      prefix = "incoming/"
    }

    expiration {
      days = 14
    }
  }

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "RefusePlaintextTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.mail.arn, "${aws_s3_bucket.mail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # SES, and only for this account's rule set, and only under `incoming/`.
  statement {
    sid       = "ReceiveFromSes"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.mail.arn}/incoming/*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:ses:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:receipt-rule-set/${var.receipt_rule_set_name}:receipt-rule/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "mail" {
  bucket     = aws_s3_bucket.mail.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.mail]
}

# The server's table. Its layout is the server's business; what is fixed here is what the
# server's DynamoDB backend asks for: string keys `pk` and `sk`, and `expires_at` as the
# time-to-live attribute.
resource "aws_dynamodb_table" "metadata" {
  name                        = var.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.protect

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}

output "bucket_name" {
  value = aws_s3_bucket.mail.id
}

output "bucket_arn" {
  value = aws_s3_bucket.mail.arn
}

output "table_name" {
  value = aws_dynamodb_table.metadata.name
}

output "table_arn" {
  value = aws_dynamodb_table.metadata.arn
}

# Depend on this to be sure SES is allowed to write before a rule that makes it write exists.
output "bucket_policy_id" {
  value = aws_s3_bucket_policy.mail.id
}
