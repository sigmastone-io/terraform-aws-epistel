# terraform-aws-epistel roadmap

## Release 0.1

Design in [design.md](design.md). Tracks Epistel 0.1.

Built:

- Storage: bucket and table.
- Mail flow: receipt rule in an existing rule set, topic, inbound queue,
  dead-letter queue with alarm.
- Compute: one EC2 instance running the server's image, Elastic IP, role,
  log group, recovery alarm, certificate from an ACME authority through
  Route 53.
- Declared mailboxes rendered into the server's configuration.
- Create-or-point-at for the network, the ECR repository and the rule set.
- `deploy/`: a deployment driven by one ignored configuration file, with
  local state.

Still to do before 0.1:

- A first apply against a real account. Nothing here has been applied yet;
  it is formatted and validated only.
- Checks in continuous integration.
- Examples and registry publication.

## Not in 0.1

| Item | Note |
|---|---|
| An existing instance | Installing onto an instance the module did not make, through Systems Manager. The module then controls neither its operating system nor its role. |
| An image for ARM | Lets the instance be a `t4g`, the cheapest type. |
| A key of the deployer's own | Customer-managed KMS key for bucket, table, queues and topic. |
| Fargate behind a Network Load Balancer | Managed certificate, no host to patch; costs roughly three times as much. A `compute-fargate` submodule. |
| ECS on EC2, Kubernetes | Further compute submodules or documented recipes. |
| More than one instance | Follows the server's shared change bus. |
| SES identity management | An optional submodule that creates the domain identity, DKIM and MAIL FROM records for accounts starting from nothing. |
| Service discovery records | `_imaps._tcp` and `_submissions._tcp` records per mail domain, and a Thunderbird autoconfig document. |
| Bounce and complaint event pipeline | Configuration set and event destination, once the server reads them. |
| Dashboards | CloudWatch dashboard and more alarms, once the server exports metrics. |
| Backup to a second region | Bucket replication and table global tables. |
| Certificates without Route 53 | DNS challenge providers other than Route 53, or certificate files handed over. |
| Shared state | A remote backend for `deploy/`, for more than one operator. |
| Other clouds | Separate modules, when the server has backends for them. |
