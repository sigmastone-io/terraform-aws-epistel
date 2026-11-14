# SPDX-FileCopyrightText: 2026 Sigmastone OÜ
# SPDX-License-Identifier: Apache-2.0

# From SES to the server: one receipt rule, one topic, one queue.
#
# The rule stores each received message in the bucket and publishes the receipt notification,
# which carries the envelope recipients and the scan verdicts, to the topic. The topic feeds the
# queue the server reads. No function is involved.

variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "rule_set_name" {
  description = "The receipt rule set the rule is added to. It has to be the active one to have any effect."
  type        = string
}

variable "after_rule" {
  description = "Name of the rule to place this one after. Null puts it first."
  type        = string
  default     = null
}

variable "recipients" {
  description = "Addresses and domains the rule accepts mail for."
  type        = list(string)

  validation {
    condition     = length(var.recipients) > 0
    error_message = "A receipt rule without recipients matches every address of every verified domain."
  }
}

variable "tls_policy" {
  description = "Whether senders must use TLS: Require or Optional."
  type        = string
  default     = "Optional"
}

variable "bucket_name" {
  type = string
}

variable "alarm_actions" {
  description = "ARNs to notify when mail is stuck in the dead-letter queue."
  type        = list(string)
  default     = []
}

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "receipts" {
  name = "${var.name}-receipts"
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "PublishFromSes"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.receipts.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "receipts" {
  arn    = aws_sns_topic.receipts.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Where a notification goes after the server failed on it five times, or could not read it at
# all. The raw message is still in the bucket at that point.
resource "aws_sqs_queue" "dead_letters" {
  name                      = "${var.name}-inbound-dead-letters"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "inbound" {
  name                       = "${var.name}-inbound"
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letters.arn
    maxReceiveCount     = 5
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "DeliverFromTopic"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.inbound.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.receipts.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "inbound" {
  queue_url = aws_sqs_queue.inbound.id
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_sns_topic_subscription" "inbound" {
  topic_arn            = aws_sns_topic.receipts.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.inbound.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.inbound]
}

# One action: store, and say so on the topic. Other rules of the set are not touched, and no
# stop action is added, so a message that also matches a rule further down is handled by that
# rule as well.
resource "aws_ses_receipt_rule" "inbound" {
  name          = var.name
  rule_set_name = var.rule_set_name
  after         = var.after_rule
  recipients    = var.recipients
  enabled       = true
  scan_enabled  = true
  tls_policy    = var.tls_policy

  s3_action {
    position          = 1
    bucket_name       = var.bucket_name
    object_key_prefix = "incoming/"
    topic_arn         = aws_sns_topic.receipts.arn
  }

  depends_on = [aws_sns_topic_policy.receipts, aws_sns_topic_subscription.inbound]

}

resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  alarm_name          = "${var.name}-inbound-dead-letters"
  alarm_description   = "Received mail could not be filed and is waiting in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions

  dimensions = {
    QueueName = aws_sqs_queue.dead_letters.name
  }
}

output "queue_url" {
  value = aws_sqs_queue.inbound.url
}

output "queue_arn" {
  value = aws_sqs_queue.inbound.arn
}

output "dead_letter_queue_url" {
  value = aws_sqs_queue.dead_letters.url
}

output "topic_arn" {
  value = aws_sns_topic.receipts.arn
}
