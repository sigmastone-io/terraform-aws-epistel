# terraform-aws-epistel design

Design of the first release (0.1). The server it deploys is described in the
Epistel repository under `doc/architecture.md`.

## 1. Goal

One configuration file gives a working mail server for addresses that SES
already receives for, at the lowest running cost AWS allows, with nothing
specific to any one organization.

## 2. What the module makes, and what it is pointed at

Makes:

- the bucket for received and stored mail
- the metadata table
- the topic and queues that carry receipt notifications
- one SES receipt rule
- the instance, its address, security group, role and certificate
- the address record of the host name
- optionally: a small network, an ECR repository, a receipt rule set

Is pointed at, and never makes:

- **The addresses.** Mail addresses are declared, not created. Each has to be
  an address of a domain SES already receives for. The module uses the list
  for the receipt rule; the server uses it to keep one mailbox per address.
- **SES domain identities.** Verified domains, DKIM and the MAIL FROM domain
  exist already and are shared with other senders.
- **The receipt rule set.** SES allows one active rule set per account and
  region. An account that receives mail has one, and a module that activated
  its own would switch the existing rules off. The module adds one rule to
  the rule set it is told about. Only in an account that receives no mail
  yet may it be asked to create and activate one.
- **The DNS zone** of the host name.
- **The image.** Built and published by the server's repository. A public
  image is pulled as it is; one in a private ECR repository is pulled with
  the instance's role.
- **Leaving the SES sandbox** and sending limits, which are account settings.

## 3. Resources

```
  MX --> SES receiving --rule--> S3 bucket  incoming/
                           |
                           +--> SNS topic --> SQS queue --> dead-letter queue
                                                 |
                                                 v
  clients --993/465--> Elastic IP --> EC2 instance (container: epistel)
                                         |    |    |
                                DynamoDB table |  SES send API
                                         S3 bucket  blobs/  state/
```

No Lambda function. The receipt rule's S3 action publishes the receipt
notification itself.

### Mail flow (`modules/ses-inbound`)

| Resource | Purpose |
|---|---|
| `aws_ses_receipt_rule` | Accepts the declared addresses. One S3 action: store under `incoming/`, notify the topic. Scanning on. Placed first in the rule set unless told which rule to follow. No stop action: rules further down still see the message. |
| `aws_sns_topic` and policy | Receives the notification. Only SES in this account may publish. |
| `aws_sqs_queue` (inbound) | Subscribed with raw message delivery. Long polling, five attempts. |
| `aws_sqs_queue` (dead letters) | Notifications that failed five times or could not be read. An alarm fires when it is not empty. |

### Storage (`modules/storage`)

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | `incoming/` written by SES, `blobs/` by the server, `state/` by the instance. Public access blocked, versioning on, TLS only. `incoming/` expires after 14 days as a backstop; old versions after 30. |
| `aws_dynamodb_table` | Partition key `pk`, sort key `sk`, both strings, no indexes. On-demand billing, point-in-time recovery, time-to-live on `expires_at`. Deletion protection. |

Encryption at rest uses keys the services manage. A key of the deployer's
own is on the roadmap: it costs a monthly fee and needs grants for SES and
SNS.

### Compute (`modules/compute-ec2`)

The cheapest shape that works: one small instance with a public address and
no load balancer.

| Resource | Purpose |
|---|---|
| `aws_instance` | `t3.micro` by default, Amazon Linux 2023, x86-64. Metadata service version 2 only. Encrypted root volume. No SSH key. |
| `aws_eip` | A stable address for the host name. |
| `aws_security_group` | In: 993 and 465 from the configured ranges. Out: anything. |
| `aws_iam_role` and profile | See permissions below. Includes Session Manager, which is how an operator gets a shell. |
| `aws_route53_record` | The host name's address record. |
| `aws_cloudwatch_log_group` | The server's log. |
| Alarm | Moves the instance to healthy hardware when the system check fails. |
| Network, optional | Without a subnet to run in: a VPC with one public subnet and an internet gateway. |

The instance keeps nothing. Any change to the image or the configuration
replaces it; the address moves to the new one.

First boot:

1. Install the container runtime.
2. Write the server's configuration, which Terraform renders: host name,
   backends, and the declared mailboxes.
3. Obtain the certificate (below).
4. Run the image as a systemd service: unprivileged inside the container,
   ports 993 and 465 published, configuration mounted read-only, output to
   the log group. The service pulls the image by the reference it was given
   and logs in to ECR first when the image is there.

### Certificate

The server reads its certificate from files and takes over new ones when they
change. With no load balancer there is no managed certificate, so the
instance gets one from an ACME certificate authority:

- An ACME client, run as a container, proves control of the host name with a
  DNS record in the zone. The instance may change the `_acme-challenge` TXT
  record of that one name and nothing else in the zone.
- Certificate, key and account are copied to `state/` in the bucket, so a
  replacement instance reuses them and does not ask for a new certificate.
- A timer renews twice a day when less than 30 days are left.
- If the first attempt fails, the server is restarted until the timer
  succeeds.

### Mailboxes and passwords

The declared addresses are written into the server's configuration. The
server makes a mailbox for each that has none when it starts, and never
removes one. Terraform sets no passwords: they would sit in its state. The
`password_commands` output lists, per mailbox, the command an operator runs
in a Session Manager shell; it prints an app password once.

## 4. Permissions of the instance

| Access | Scope |
|---|---|
| Read, write, delete objects; list | this bucket |
| Read and write items | this table |
| Receive and delete messages | the inbound queue |
| `ses:SendEmail` and `ses:SendRawEmail` | the listed identities only. Both names are needed: the v2 send API with raw content, which is how the server sends, authorizes against the older name. |
| Pull the image | the one ECR repository, when the image is in ECR |
| Change one TXT record | `_acme-challenge.<host name>` in the zone |
| Write logs | this log group |
| Session Manager | this instance |

Two actions have no narrower resource than `*`: the ECR login token and the
status of a DNS change.

## 5. Running it

The module is used like any other, or directly through `deploy/`:

```
deploy/
  main.tf               reads config.yaml, configures the provider, calls the module
  config.example.yaml   the shape of the configuration
  config.yaml           one deployment's values; ignored by git
  terraform.tfstate     local state; ignored by git
```

`config.yaml` holds the region, host name, zone, image, repository, SES
identities, rule set, certificate contact, and the mailboxes. Things that
exist are named in it; the zone is looked up by name.

## 6. Receipt rule placement

Rules in a set run in order, and a message can match several. An account
that already forwards mail keeps doing so once this module's rule is added: a
message for a declared address is then both forwarded and stored. That is
what a trial wants, and what a cut-over ends by removing the old rule. The
module does not touch other rules.

## 7. Layout

```
main.tf, variables.tf, outputs.tf, versions.tf    the module: renders the server's configuration, wires the parts
modules/
  storage/          bucket, table
  ses-inbound/      receipt rule, topic, queues
  compute-ec2/      instance, address, network, role, certificate, boot script
deploy/             a ready-made deployment driven by one file
doc/
```

Compute is its own submodule so that other shapes can be added beside it
without changing storage or mail flow.

## 8. Cost

Approximate monthly cost, light use:

| Item | USD |
|---|---|
| `t3.micro` instance | 8 |
| Public IPv4 address | 3.7 |
| Root volume, 16 GB | 1.3 |
| DynamoDB, S3, SQS, SNS, logs | under 1 |
| **Total** | **about 14** |

A `t3.nano` or, with an image built for it, a `t4g.nano` brings this to about
9. The default leaves room for the operating system's own package work on
first boot. SES charges for mail received and sent are separate and small at
this scale.

## 9. Constraints

- SES receives mail only in some regions. The module is applied in the
  region whose rule set it is told about.
- SES accepts messages up to 40 MB, inbound and outbound.
- One active receipt rule set per account and region.
- A new SES account is in the sandbox and sends only to verified addresses
  until AWS lifts the restriction.
- The image is built for x86-64.

## 10. Quality

- `terraform fmt` and `terraform validate` on the module and on `deploy/`.
- Provider and Terraform versions pinned with lower bounds only.
- Releases are tagged with semantic versions so the module can be published
  to the Terraform Registry.
