# lingo-infra

Terraform for Lingo backend infrastructure.

State is **local** (`terraform.tfstate` in this directory, gitignored). Use remote state (e.g. S3) when you are ready for shared / CI applies.

## DynamoDB tables

```bash
terraform init
terraform plan
terraform apply
```

Optional variables (defaults suit local dev):

- `table_prefix` — default `lingo_` (set e.g. `lingo_dev_` for a separate prefix).
- `aws_region` — default `us-west-1`.

Example one-off:

```bash
terraform apply -var='table_prefix=lingo_dev_' -var='aws_region=us-west-1'
```

Creates four tables (prefix `lingo_` by default):

| Table                   | Purpose                                       |
|-------------------------|-----------------------------------------------|
| `lingo_users`           | Users, settings                               |
| `lingo_subscriptions`   | User content subscriptions (decks, addons, …) |
| `lingo_srs`             | Per-user SRS card state                       |
| `lingo_decks`           | Deck manifests and content                    |

Set `DYNAMODB_TABLE_PREFIX` and `AWS_REGION` in lingo-core to match.

## CI

GitHub Actions runs `terraform fmt -check`, `terraform init`, and `terraform validate` when `lingo-infra/` changes (no AWS credentials; no remote backend).
