variable "name" {
  description = "Prefix for the names of everything this module makes."
  type        = string
  default     = "epistel"
}

variable "hostname" {
  description = "The name mail clients connect to, for example mail.example.org. The certificate is issued for it."
  type        = string
}

variable "mailboxes" {
  description = <<-EOT
    The addresses mail is received for. They are declared here, not created: each has to be an
    address of a domain that SES already receives for. Every entry becomes a mailbox with its own
    login; aliases deliver into the same mailbox. The server makes missing mailboxes when it
    starts and never removes one. Passwords are not set here; see the `password_commands` output.
  EOT
  type = list(object({
    address = string
    name    = optional(string, "")
    aliases = optional(list(string), [])
  }))

  validation {
    condition     = length(var.mailboxes) > 0
    error_message = "Declare at least one mailbox."
  }

  validation {
    condition     = alltrue([for mailbox in var.mailboxes : can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", mailbox.address))])
    error_message = "Every mailbox address has to be a full mail address."
  }
}

variable "image" {
  description = "The server's container image, ideally by digest: <registry>/<repository>@sha256:<digest>."
  type        = string
}

variable "ecr" {
  description = <<-EOT
    The ECR repository the image comes from, so that the instance is allowed to pull it. Either
    point at an existing one with `repository_arn`, or set `create` to have one made under the
    module's name. Leave both out for an image in a public registry.
  EOT
  type = object({
    create         = optional(bool, false)
    repository_arn = optional(string)
  })
  default = {}
}

variable "ses_identities" {
  description = "The verified SES identities (domains) the server may send from. They exist already; this module does not make them."
  type        = list(string)
}

variable "receipt" {
  description = <<-EOT
    The receipt rule set the module adds its rule to. An account that already receives mail has an
    active one: name it, and say with `after_rule` where the new rule goes (leave out for first).
    Set `create_rule_set` only in an account that receives no mail yet.
  EOT
  type = object({
    rule_set_name   = string
    create_rule_set = optional(bool, false)
    after_rule      = optional(string)
    tls_policy      = optional(string, "Optional")
  })
}

variable "zone_id" {
  description = "The Route 53 zone that holds the host name."
  type        = string
}

variable "acme" {
  description = "The certificate authority account: contact address, and optionally another directory or client image."
  type = object({
    email         = string
    directory_url = optional(string, "https://acme-v02.api.letsencrypt.org/directory")
    client_image  = optional(string, "docker.io/goacme/lego:v4.19.2")
  })
}

variable "network" {
  description = "An existing public subnet to run in. Left empty, the module makes a small network of its own."
  type = object({
    subnet_id = optional(string)
    cidr      = optional(string, "10.90.0.0/24")
  })
  default = {}
}

variable "allowed_cidrs" {
  description = "Who may connect to the mail ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_type" {
  description = "The instance type. An x86-64 type: that is what the image is built for."
  type        = string
  default     = "t3.micro"
}

variable "max_message_size" {
  description = "The largest message a client may send or append."
  type        = string
  default     = "40MB"
}

variable "bucket_name" {
  description = "Name of the mail bucket. The default is made of the module's name, the account and the region."
  type        = string
  default     = null
}

variable "protect_data" {
  description = "Refuse to destroy the table, and the bucket while it holds mail."
  type        = bool
  default     = true
}

variable "alarm_actions" {
  description = "ARNs to notify when received mail could not be filed."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}
