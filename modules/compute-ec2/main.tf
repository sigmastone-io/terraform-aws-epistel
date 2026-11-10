# The cheapest shape that runs the server: one small instance with a public address, running the
# container image, with a certificate it fetches itself.
#
# The instance keeps nothing. Mail is in the bucket and the table; the certificate is copied to
# the bucket so that a replacement finds it. Any change to the image or to the configuration
# replaces the instance, and the address moves to the new one.

variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "hostname" {
  description = "The name clients connect to. The certificate is issued for it."
  type        = string
}

variable "image" {
  description = "The server's container image, ideally by digest."
  type        = string
}

variable "config" {
  description = "The server's configuration file, as text."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "subnet_id" {
  description = "An existing public subnet to run in. Null creates a small network of its own."
  type        = string
  default     = null
}

variable "network_cidr" {
  description = "Address range of the network that is created when no subnet is given."
  type        = string
  default     = "10.90.0.0/24"
}

variable "allowed_cidrs" {
  description = "Who may connect to the mail ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "zone_id" {
  description = "The Route 53 zone that holds the host name: for its address record and for proving control of the name to the certificate authority."
  type        = string
}

variable "acme" {
  description = "The certificate authority account: contact address, directory, and the client image that talks to it."
  type = object({
    email         = string
    directory_url = optional(string, "https://acme-v02.api.letsencrypt.org/directory")
    client_image  = optional(string, "docker.io/goacme/lego:v4.19.2")
  })
}

variable "bucket_name" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "ses_identity_arns" {
  description = "The SES identities the server may send from."
  type        = list(string)
}

variable "ecr_repository_arn" {
  description = "The ECR repository the image is pulled from, when it is in ECR."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 30
}

data "aws_region" "current" {}
data "aws_partition" "current" {}

# Amazon Linux 2023, whatever is current when the instance is first made. A newer image later
# does not replace a running instance; see `ignore_changes` below.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -------------------------------------------------------------------------------------------------
# Network: an existing public subnet, or the smallest one that works
# -------------------------------------------------------------------------------------------------

locals {
  create_network = var.subnet_id == null
  subnet_id      = local.create_network ? aws_subnet.public[0].id : var.subnet_id
}

data "aws_subnet" "given" {
  count = local.create_network ? 0 : 1
  id    = var.subnet_id
}

data "aws_availability_zones" "available" {
  count = local.create_network ? 1 : 0
  state = "available"
}

resource "aws_vpc" "own" {
  count                = local.create_network ? 1 : 0
  cidr_block           = var.network_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_internet_gateway" "own" {
  count  = local.create_network ? 1 : 0
  vpc_id = aws_vpc.own[0].id
}

resource "aws_subnet" "public" {
  count             = local.create_network ? 1 : 0
  vpc_id            = aws_vpc.own[0].id
  cidr_block        = var.network_cidr
  availability_zone = data.aws_availability_zones.available[0].names[0]

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table" "public" {
  count  = local.create_network ? 1 : 0
  vpc_id = aws_vpc.own[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.own[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = local.create_network ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_security_group" "server" {
  name_prefix = "${var.name}-"
  description = "Mail clients in, on the two TLS ports. Nothing else in."
  vpc_id      = local.create_network ? aws_vpc.own[0].id : data.aws_subnet.given[0].vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "mail" {
  for_each = { for pair in setproduct(var.allowed_cidrs, [993, 465]) : "${pair[0]}-${pair[1]}" => pair }

  security_group_id = aws_security_group.server.id
  description       = each.value[1] == 993 ? "IMAP over TLS" : "Submission over TLS"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

# Out: the cloud services, the image registry, the certificate authority.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.server.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -------------------------------------------------------------------------------------------------
# What the instance may do
# -------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "server" {
  statement {
    sid       = "Messages"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    sid       = "FindMessages"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }

  # Transactions are authorized as the single writes they are made of.
  statement {
    sid = "Metadata"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [var.table_arn]
  }

  statement {
    sid       = "ReceivedMail"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }

  # Both names: the v2 send API with raw content, which is how the server sends, is authorized
  # against the older `SendRawEmail` as well.
  statement {
    sid       = "Send"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = var.ses_identity_arns
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.server.arn}:*"]
  }

  # Proving control of the host name: one TXT record, nothing else in the zone.
  statement {
    sid       = "CertificateChallenge"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.${lower(var.hostname)}"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  # These two have no narrower resource to name.
  statement {
    sid       = "CertificateChallengeStatus"
    actions   = ["route53:GetChange", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.ecr_repository_arn == null ? [] : [var.ecr_repository_arn]

    content {
      sid       = "PullImage"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = [statement.value]
    }
  }

  dynamic "statement" {
    for_each = var.ecr_repository_arn == null ? [] : [1]

    content {
      sid       = "RegistryLogin"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "server" {
  name   = "server"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

# A shell on the instance without SSH: this is how an operator issues app passwords.
resource "aws_iam_role_policy_attachment" "session" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "server" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.server.name
}

resource "aws_cloudwatch_log_group" "server" {
  name              = "/${var.name}/server"
  retention_in_days = var.log_retention_days
}

# -------------------------------------------------------------------------------------------------
# The instance
# -------------------------------------------------------------------------------------------------

resource "aws_instance" "server" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.server.id]
  iam_instance_profile        = aws_iam_instance_profile.server.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/boot.sh.tftpl", {
    config         = var.config
    image          = var.image
    hostname       = lower(var.hostname)
    region         = data.aws_region.current.region
    bucket         = var.bucket_name
    zone_id        = var.zone_id
    acme_email     = var.acme.email
    acme_directory = var.acme.directory_url
    acme_client    = var.acme.client_image
    log_group      = aws_cloudwatch_log_group.server.name
  })

  # Version 2 of the metadata service only. Two hops, because the server asks from inside a
  # container, one network hop away from the instance.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
    encrypted   = true
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    # A new Amazon Linux release must not replace a running mail server on some unrelated apply.
    # The operating system is renewed whenever the image or the configuration changes.
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy.server, aws_iam_role_policy_attachment.session]
}

resource "aws_eip" "server" {
  domain = "vpc"

  tags = {
    Name = var.name
  }
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}

resource "aws_route53_record" "server" {
  zone_id = var.zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.server.public_ip]
}

# The hardware under the instance failing is the one failure that needs no decision.
resource "aws_cloudwatch_metric_alarm" "recover" {
  alarm_name          = "${var.name}-recover"
  alarm_description   = "Moves the instance to healthy hardware when the system status check fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:${data.aws_partition.current.partition}:automate:${data.aws_region.current.region}:ec2:recover"]

  dimensions = {
    InstanceId = aws_instance.server.id
  }
}

output "instance_id" {
  value = aws_instance.server.id
}

output "public_ip" {
  value = aws_eip.server.public_ip
}

output "role_arn" {
  value = aws_iam_role.server.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.server.name
}
