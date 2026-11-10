# terraform-aws-epistel

Terraform module that runs [Epistel](https://github.com/sigmastone-io/epistel)
on AWS and connects it to Amazon SES: the receipt rule, the storage, the
queue, the instance and its permissions.

Status: written, formatted and validated; not yet applied to an account. See:

- [doc/design.md](doc/design.md) - the design
- [doc/roadmap.md](doc/roadmap.md) - first release and what comes later

## Using it

Mail addresses are declared, not created: SES already receives for them, and
the module is told which ones the server should hold mailboxes for.

The shortest way is the ready-made deployment in `deploy/`:

```
cd deploy
cp config.example.yaml config.yaml      # fill in; git ignores it
terraform init
terraform plan
terraform apply
```

`config.yaml` and the state file stay on the machine that applies them.

Afterwards the `password_commands` output lists, per mailbox, the command
that issues an app password. Passwords never pass through Terraform.

In a mail client: the host name from the `hostname` output, port 993 for
incoming and 465 for outgoing mail, both SSL/TLS, the address as the user
name and the app password as the password.

## License

Apache-2.0. See [LICENSE](LICENSE).
