# terraform-aws-epistel

Terraform module that runs [Epistel](https://github.com/sigmastone-io/epistel), the open source
mail server for domains on Amazon SES, on AWS and connects it to SES. Given a domain SES already
receives mail for, one module call gives working IMAP and SMTP Submission mailboxes for the
addresses you declare, at the lowest running cost AWS allows.

> **Status: pre-release.** The module is formatted and validated; the first apply against a real
> account, checks in CI and registry publication are still open (see
> [doc/roadmap.md](doc/roadmap.md)). It tracks Epistel 0.1, which has no compatibility promises
> before 1.0.

## What it creates

| Part | Resources |
|---|---|
| Mail flow (`modules/ses-inbound`) | One SES receipt rule in an existing rule set: accepts the declared addresses, stores the message under `incoming/` in the bucket, notifies the topic, scanning on, no stop action. An SNS topic only SES in this account may publish to. An SQS queue subscribed with raw delivery, and a dead-letter queue with an alarm when it is not empty. |
| Storage (`modules/storage`) | An S3 bucket (`incoming/` from SES, `blobs/` from the server, `state/` for the certificate): public access blocked, versioning, TLS only, encryption with S3-managed keys. A DynamoDB table: on-demand, point-in-time recovery, time-to-live, deletion protection. |
| Compute (`modules/compute-ec2`) | One EC2 instance (Amazon Linux 2023, x86-64, `t3.micro` by default, IMDSv2 only, encrypted root volume, no SSH key) running the Epistel container as a systemd service. An Elastic IP and the host name's Route 53 record. A security group open on 993 and 465 only. An IAM role scoped to the module's own resources, with Session Manager for shell access. A log group and a recovery alarm. A certificate from Let's Encrypt (or another ACME authority) through a DNS challenge, kept in the bucket so a replacement instance reuses it. |
| Optional | A small VPC with one public subnet, when no subnet is given. An ECR repository, when `ecr.create` is set. A receipt rule set, created and activated, when `receipt.create_rule_set` is set. |

No Lambda function: the receipt rule's S3 action carries the event. The instance holds no state;
any change to the image or the configuration replaces it, and the address moves to the new one.

What the module is pointed at and never makes: the mail addresses, the SES domain identities
(with DKIM and MAIL FROM), the receipt rule set (unless asked), the DNS zone, the container image,
and leaving the SES sandbox.

The design, with the instance's permissions resource by resource, is in
[doc/design.md](doc/design.md).

## Prerequisites

- An AWS account with SES **already receiving** mail for the domain: MX record pointing at SES
  inbound in a region that supports receiving, and an active receipt rule set. The module is
  applied in that region.
- Verified SES identities for every domain the server sends from. A new account is in the SES
  sandbox and sends only to verified addresses until AWS lifts the restriction.
- A public Route 53 hosted zone that holds the server's host name.
- Terraform 1.6 or newer, AWS provider 6.0 or newer.
- The Epistel container image, by digest. The public image needs nothing else; one in a private
  ECR repository also needs `ecr`.

> **Warning: one active receipt rule set per account and region.** SES allows only one active rule
> set, and activating another switches every existing rule off. In an account that already
> receives mail, name the active rule set in `receipt.rule_set_name` and leave
> `create_rule_set` unset; the module then adds one rule and touches no other. Set
> `create_rule_set = true` only in an account that receives no mail at all yet.

Rules in a set run in order and a message can match several. A rule that already forwards mail
for a declared address keeps doing so: the message is then both forwarded and stored, which is
what a trial wants. Removing the old rule is the cut-over.

## Usage

```hcl
module "epistel" {
  source = "git::https://github.com/sigmastone-io/terraform-aws-epistel.git?ref=v0.1.0"

  hostname = "mail.example.org"
  zone_id  = "Z0123456789EXAMPLE"
  image    = "ghcr.io/sigmastone-io/epistel@sha256:<digest>"

  ses_identities = ["example.org"]

  receipt = {
    rule_set_name = "example-inbound" # the rule set already active in the account
  }

  acme = {
    email = "postmaster@example.org"
  }

  mailboxes = [
    { address = "ada@example.org", name = "Ada", aliases = ["sales@example.org"] },
    { address = "support@example.org" },
  ]
}
```

Pin `ref` to a release tag (or a commit) and the image to a digest, so that a plan changes only
when you change them.

Mail addresses are declared, never created: each must be an address of a domain SES already
receives for. Every entry becomes a mailbox with its own login; aliases deliver into it. The
server makes missing mailboxes when it starts and never removes one.

### Passwords

Terraform never sees a password; it would end up in the state. After the apply, open a shell on
the instance with the `session_command` output (needs the Session Manager plugin for the AWS CLI)
and run the mailbox's command from `password_commands`:

```
sudo docker exec epistel epistel password new ada@example.org --label laptop
```

It prints an app password once. Run it again for every further device.

### Mail clients

The host name from the `hostname` output; IMAP on port 993 and SMTP on port 465, both SSL/TLS; the
mailbox's address as user name and the app password as password.

## The `deploy/` example

[deploy/](deploy/) is a ready-made root configuration that calls this module, driven by one YAML
file:

```
cd deploy
cp config.example.yaml config.yaml    # fill in
terraform init
terraform plan
terraform apply
```

It configures the provider (region, optional profile, default tags), looks up the zone by name and
keeps its state in a local file. `config.yaml` and `terraform.tfstate` are ignored by git and stay
on the machine that applies them; move the state to a shared backend when more than one person
applies. [config.example.yaml](deploy/config.example.yaml) documents every key.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|:---:|
| `hostname` | The name mail clients connect to, for example `mail.example.org`. The certificate is issued for it. | `string` | | yes |
| `zone_id` | The Route 53 zone that holds the host name. | `string` | | yes |
| `image` | The server's container image, ideally by digest: `<registry>/<repository>@sha256:<digest>`. | `string` | | yes |
| `mailboxes` | The addresses mail is received for, declared not created. At least one. | `list(object({ address = string, name = optional(string, ""), aliases = optional(list(string), []) }))` | | yes |
| `ses_identities` | Verified SES identities (domains) the server may send from. | `list(string)` | | yes |
| `receipt` | The receipt rule set the rule is added to, the rule to place it after (first when left out), whether to create and activate the rule set, and the rule's TLS policy. | `object({ rule_set_name = string, create_rule_set = optional(bool, false), after_rule = optional(string), tls_policy = optional(string, "Optional") })` | | yes |
| `acme` | The certificate authority account: contact address, and optionally another directory or client image. | `object({ email = string, directory_url = optional(string, "https://acme-v02.api.letsencrypt.org/directory"), client_image = optional(string, "docker.io/goacme/lego:v4.19.2") })` | | yes |
| `name` | Prefix for the names of everything the module makes. | `string` | `"epistel"` | no |
| `ecr` | For an image in a private ECR repository: point at it with `repository_arn`, or set `create` to have one made. Leave out for a public image. | `object({ create = optional(bool, false), repository_arn = optional(string) })` | `{}` | no |
| `network` | An existing public subnet to run in; left empty, the module makes a small network with `cidr`. | `object({ subnet_id = optional(string), cidr = optional(string, "10.90.0.0/24") })` | `{}` | no |
| `allowed_cidrs` | Who may connect to the mail ports. | `list(string)` | `["0.0.0.0/0"]` | no |
| `instance_type` | An x86-64 instance type; that is what the image is built for. | `string` | `"t3.micro"` | no |
| `max_message_size` | The largest message a client may send or append. | `string` | `"40MB"` | no |
| `bucket_name` | Name of the mail bucket. The default is made of the module's name, the account and the region. | `string` | `null` | no |
| `protect_data` | Refuse to destroy the table, and the bucket while it holds mail. | `bool` | `true` | no |
| `alarm_actions` | ARNs to notify when received mail could not be filed. | `list(string)` | `[]` | no |
| `log_retention_days` | Retention of the server's log group, in days. | `number` | `30` | no |

## Outputs

| Name | Description |
|---|---|
| `hostname` | What to enter in a mail client: this name, port 993 for incoming and 465 for outgoing, both SSL/TLS. |
| `public_ip` | The instance's Elastic IP address. |
| `instance_id` | The instance's id. |
| `bucket` | The mail bucket's name. |
| `table` | The metadata table's name. |
| `queue_url` | The inbound queue's URL. |
| `dead_letter_queue_url` | The dead-letter queue's URL. |
| `log_group` | The server's log group. |
| `repository_url` | The repository to push the image to, when the module made it. |
| `recipients` | Every address the receipt rule accepts mail for. |
| `session_command` | Opens a shell on the instance through Session Manager. |
| `password_commands` | Per mailbox, the command that issues an app password. |

## Cost

The default shape is the cheapest one that works: one small instance with a public address and no
load balancer. Approximate monthly cost at light use:

| Item | USD |
|---|---|
| `t3.micro` instance | 8 |
| Public IPv4 address | 3.7 |
| Root volume, 16 GB | 1.3 |
| DynamoDB, S3, SQS, SNS, logs | under 1 |
| **Total** | **about 14** |

SES charges for mail received and sent come on top and are small at this scale. A `t3.nano` brings
the total to about 9. The price of one instance is no redundancy: if the instance fails, the
recovery alarm moves it to healthy hardware, and a replacement starts from the same table, bucket
and certificate, but clients cannot connect until it is up. Received mail waits in the queue in
the meantime. Other shapes (Fargate behind a Network Load Balancer, more than one instance) are on
the roadmap.

## Licence

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE).

---

terraform-aws-epistel is made by [Sigmastone](https://sigmastone.io). © 2026 Sigmastone OÜ.
