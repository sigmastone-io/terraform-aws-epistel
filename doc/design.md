# terraform-aws-epistel design

Design for the first release (0.1). The server it deploys is described in
the Epistel repository under `doc/architecture.md`.

## 1. Goal

One `module` block gives a working mail server for domains hosted on SES,
at the lowest running cost AWS allows, with nothing specific to any one
organization.

## 2. What the module owns, and what it does not

Owns:

- the bucket for received and stored mail
- the topic and queues that carry receipt events
- one SES receipt rule
- the metadata table
- the encryption key
- the instance, its address, its security group and its role
- optionally, DNS records in Route 53

Does not own, and takes as input:

- **SES domain identities.** Verified domains, DKIM and the custom MAIL FROM
  domain usually exist already and are shared with other senders.
- **The receipt rule set.** SES allows one active rule set per account and
  region. An account that already receives mail has one, and a module that
  created and activated its own would switch the existing rules off. The
  module therefore adds its rule to a rule set named by the caller, at a
  position chosen by the caller. A small optional submodule creates and
  activates a rule set for accounts that have none.
- **The network.** VPC and public subnet are inputs. The example
  configurations show the default VPC.
- **Leaving the SES sandbox** and sending limits. These are account
  settings.

## 3. Resources

```
  MX --> SES receiving --rule--> S3 bucket  incoming/
                           |
                           +--> SNS topic --> SQS queue --> dead-letter queue
                                                 |
                                                 v
  clients --993/465--> Elastic IP --> EC2 instance (epistel)
                                         |    |    |
                                DynamoDB table |  SES send API
                                         S3 bucket  blobs/
```

No Lambda function is needed. The receipt rule's S3 action publishes the
receipt event itself.

### Mail flow

| Resource | Purpose |
|---|---|
| `aws_ses_receipt_rule` | Matches the configured recipient domains or addresses. One S3 action: store under `incoming/`, notify the topic. TLS required, scanning enabled. |
| `aws_sns_topic` and policy | Receives the receipt event from SES. Only SES in this account may publish. |
| `aws_sqs_queue` (inbound) | Subscribed to the topic with raw message delivery. Long polling. Visibility timeout sized for one ingest attempt. |
| `aws_sqs_queue` (dead letter) | Receives events that failed repeatedly. An alarm fires when it is not empty. |

### Storage

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | Prefix `incoming/` written by SES, prefix `blobs/` written by the server. Public access blocked, versioning on, TLS-only bucket policy. Lifecycle: `incoming/` objects expire after 14 days as a backstop; old versions expire after 30 days. |
| `aws_dynamodb_table` | Single table, partition key `pk` and sort key `sk` (both strings), no secondary indexes. On-demand billing, point-in-time recovery, time-to-live on the attribute `expires_at`. |
| `aws_kms_key` | Encrypts the bucket, the table and the queues. The key policy lets SES and SNS use it for their writes. Optional: the caller may pass an existing key. |

SES can also encrypt on the client side before writing to S3. That mode is
not used: reading it back needs the S3 encryption client, and bucket
encryption gives the same protection at rest.

### Compute

The cheapest shape that works: one small instance with a public address and
no load balancer.

| Resource | Purpose |
|---|---|
| `aws_instance` | `t4g.nano` by default, Amazon Linux 2023 on ARM64, in a public subnet. Instance metadata service version 2 only. Encrypted root volume. No SSH key. |
| `aws_eip` | A stable address for the mail host name. |
| `aws_security_group` | Inbound 993 and 465 from the configured ranges (default: anywhere). Outbound HTTPS. Nothing else. |
| `aws_iam_role` and instance profile | See permissions below. Includes Systems Manager so that an operator can open a session without SSH. |
| `aws_cloudwatch_log_group` | Server logs, with a retention period. |
| Alarms | Instance status check with automatic recovery; dead-letter queue not empty. |

The instance is disposable. All state is in the table and the bucket.
Changing the server version or the configuration replaces the instance; the
address moves to the new one.

First boot, from user data:

1. Download the Epistel release binary for the pinned version and verify
   its checksum.
2. Write the configuration file from module values.
3. Fetch or issue the TLS certificate (below).
4. Start Epistel as a systemd service under an unprivileged user, with
   permission to bind the two ports and nothing more.

### TLS certificate

Epistel reads its certificate from files. With no load balancer there is no
managed certificate to attach, so the instance gets one from an ACME
certificate authority:

- An ACME client on the instance proves control of the host name with a DNS
  challenge in Route 53. The instance role may change only the
  `_acme-challenge` record of that one name.
- The certificate and key are kept in Parameter Store, encrypted, so a
  replacement instance reuses them and does not ask for a new one.
- A timer renews before expiry. Epistel picks up the new files without a
  restart.

Callers whose DNS is not in Route 53 pass a certificate through Parameter
Store themselves and switch the ACME step off.

### DNS (optional)

When given a Route 53 zone, the module creates:

- the address record for the mail host name
- service records `_imaps._tcp` and `_submissions._tcp` (RFC 6186, RFC 8314)
  so that clients can find the server

MX, SPF, DKIM and DMARC records belong with the SES identity and stay with
the caller. The module prints the values it expects as outputs.

## 4. Permissions

The instance role, least privilege:

| Access | Scope |
|---|---|
| Read, write, delete objects | this bucket |
| Read and write items | this table |
| Receive and delete messages | the inbound queue |
| `ses:SendEmail` and `ses:SendRawEmail` | the listed identities only. Both names are needed: the v2 send API with raw content, which is how the server sends, authorizes against the older name. |
| Use the key | this key, through the services above |
| Read and write the certificate parameters | the module's parameter path |
| Change the ACME challenge record | that one record name, when the ACME step is on |
| Write logs | this log group |
| Systems Manager session | this instance |

## 5. Inputs and outputs (sketch)

Inputs:

| Name | Meaning |
|---|---|
| `name` | Prefix for resource names. |
| `hostname` | Mail host name, for example `mail.example.org`. |
| `mail_domains` | Domains whose mail the server handles. |
| `ses_identity_arns` | Identities the server may send from. |
| `receipt_rule_set_name` | Existing active rule set to add the rule to. |
| `receipt_rule_after` | Name of the rule to place this one after; empty for first. |
| `recipients` | Recipient filter for the rule; default is `mail_domains`. |
| `vpc_id`, `subnet_id` | Where the instance runs. |
| `allowed_cidrs` | Who may connect to 993 and 465. |
| `epistel_version` | Release to install. |
| `instance_type` | Default `t4g.nano`. |
| `route53_zone_id` | Optional; enables DNS records and the ACME step. |
| `acme_email`, `acme_directory_url` | ACME account contact and authority. |
| `kms_key_arn` | Optional existing key. |
| `log_retention_days`, `tags` | The usual. |

Outputs: host name, public address, bucket, table, queue URL, role ARN,
and the DNS records the caller still has to publish.

## 6. Receipt rule placement

Rules in a set run in order, and a message can match several. An account
that already forwards mail with a catch-all rule will, once this module's
rule is added, both forward and store a message addressed to an Epistel
recipient. That is usually wanted during migration and unwanted afterwards.
The module does not touch other rules; the documentation explains how to
narrow the existing rule or order the two.

## 7. Layout

```
main.tf, variables.tf, outputs.tf, versions.tf    root module, wires the parts
modules/
  storage/          bucket, table, key
  ses-inbound/      receipt rule, topic, queues
  compute-ec2/      instance, address, security group, role, certificate
  rule-set/         optional: create and activate a receipt rule set
examples/
  minimal/          default VPC, Route 53 zone, existing rule set
  new-account/      also creates the rule set
doc/
```

Compute is its own submodule so that other shapes can be added beside it
without changing storage or mail flow.

## 8. Cost

Approximate monthly cost in a typical region, light use:

| Item | USD |
|---|---|
| `t4g.nano` instance | 3.1 |
| Public IPv4 address | 3.7 |
| Root volume, 8 GB | 0.7 |
| KMS key | 1.0 |
| DynamoDB, S3, SQS, SNS, logs | under 1 |
| **Total** | **about 9** |

SES charges for mail received and sent are separate and small at this
scale.

## 9. Constraints

- SES receives mail only in some regions. The module must be applied in one
  of them, and the MX record must point at that region's endpoint.
- SES accepts messages up to 40 MB, inbound and outbound.
- One active receipt rule set per account and region.
- A new SES account is in the sandbox and can send only to verified
  addresses until AWS lifts the restriction.

## 10. Quality

- `terraform fmt`, `terraform validate` and a linter in continuous
  integration.
- `terraform test` with mocked providers for the wiring; the examples are
  planned in continuous integration.
- Provider and Terraform versions pinned with lower bounds only, as is
  usual for a reusable module.
- Releases are tagged with semantic versions so the module can be published
  to the Terraform Registry.
