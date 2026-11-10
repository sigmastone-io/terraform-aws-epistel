# terraform-aws-epistel roadmap

## Release 0.1

Design in [design.md](design.md). Tracks Epistel 0.1.

- Storage: bucket, table, key.
- Mail flow: receipt rule in an existing rule set, topic, inbound queue,
  dead-letter queue.
- Compute: one EC2 instance with an Elastic IP, certificate from an ACME
  authority through Route 53.
- Optional DNS records for the host name and service discovery.
- Optional submodule that creates and activates a receipt rule set.
- Two examples.

Order of work:

1. `storage` and `ses-inbound`, usable on their own for developing the
   server's ingest.
2. `compute-ec2` once the server publishes release binaries.
3. DNS, alarms, examples, registry publication.

## Not in 0.1

| Item | Note |
|---|---|
| Fargate behind a Network Load Balancer | Managed certificate, no host to patch; costs roughly three times as much. A `compute-fargate` submodule. |
| ECS on EC2, Kubernetes | Further compute submodules or documented recipes. |
| More than one instance | Follows the server's shared change bus. |
| SES identity management | An optional submodule that creates the domain identity, DKIM and MAIL FROM records for accounts starting from nothing. |
| Client autoconfiguration hosting | Static Thunderbird autoconfig document behind a host name. |
| Bounce and complaint event pipeline | Configuration set and event destination, once the server reads them. |
| Dashboards | CloudWatch dashboard and more alarms, once the server exports metrics. |
| Backup to a second region | Bucket replication and table global tables. |
| Certificates without Route 53 | DNS challenge providers other than Route 53. |
| Other clouds | Separate modules, when the server has backends for them. |
