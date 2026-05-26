# Cost allocation tags

## Why we tag

Open Lingo runs on a tight budget — the
[Survival target](../../lingo/docs/ECONOMICS.md) is **$400–800/month**
total cloud spend. To stay inside that envelope (and, once ad revenue
lands, to compare cost vs revenue *per domain*) we need to be able to
answer two questions from a single Cost Explorer query:

1. **Which AWS service is costing us?** (Lambda? DynamoDB? CloudFront?)
2. **Which product domain is costing us?** (social? decks? srs?)

AWS gives us (1) for free via the built-in `SERVICE` dimension. (2)
requires us to attach a **cost allocation tag** to every billable
resource and then ask Cost Explorer to group by that tag.

This doc covers the tags we apply, the one-time activation step that
isn't Terraform-able, and how to query the result.

## Tags we apply

Every `aws_dynamodb_table` in `main.tf` gets three tags (via
`merge(local.common_tags, { Domain = "<value>" })`):

| Tag           | Value                                  | Set in                |
|---------------|----------------------------------------|-----------------------|
| `Project`     | `"open-lingo"`                         | `local.common_tags`   |
| `Environment` | `"dev"` / `"staging"` / `"prod"`       | `var.environment`     |
| `Domain`      | per-table (see table below)            | each resource         |

### Per-table `Domain` mapping

| Table                       | `Domain` tag |
|-----------------------------|--------------|
| `lingo_users`               | `users`      |
| `lingo_subscriptions`       | `users`      |
| `lingo_srs`                 | `srs`        |
| `lingo_decks`               | `decks`      |
| `lingo_progress`            | `progress`   |
| `lingo_social`              | `social`     |
| `lingo_social_leaderboard`  | `social`     |
| `lingo_deck_votes`          | `decks`      |

The `subscriptions` and `deck_votes` tables get their "owner-domain"
tag rather than a per-table tag because:

- Subscriptions only exist to gate user content — every row is
  user-scoped. Bucketing under `users` matches the bill mental model.
- Deck votes are part of the deck-catalog product surface; mixing them
  into `decks` makes "what does the deck product cost?" a single
  query.

When in doubt, tag by the **product domain the user-facing route
lives in**, not by the storage layout. The point of these tags is to
answer business questions, not to mirror the schema.

## One-time AWS Billing console activation

**This is the step Terraform can't do.** Cost allocation tags only
become queryable in Cost Explorer *after* they're activated in the
AWS Billing console — and the activation has a ~24-hour propagation
delay before tag-grouped queries start returning data.

Steps:

1. Sign in to AWS as the billing-admin user (the cost-reader IAM
   principal in `lingo-ops` does **not** have console-billing access on
   purpose).
2. Navigate to **AWS Billing & Cost Management** → left sidebar →
   **Cost allocation tags**.
3. Open the **User-defined tags** tab.
4. Tick the boxes next to `Project`, `Environment`, and `Domain`.
5. Click **Activate**.
6. Wait ~24 hours. Until then, any `GroupBy: { Type: "TAG", Key: "Domain" }`
   call in Cost Explorer will return a `ValidationException` — the
   `AwsCostSource` adapter in lingo-ops catches this and surfaces a clear
   message in the sync response detail. You don't need to babysit it.

If you `terraform apply` new tags after activation, no re-activation
is needed — the tag *key* is what gets activated, not individual
key/value pairs.

## Querying the result

### From AWS Cost Explorer console

- Filter → Tag → `Domain` → select one or more values
- Group by → Tag → `Domain` (or `Service` for the service breakdown)
- Granularity → Monthly (default) or Daily for trend lines

### From lingo-ops

Once a sync has run (`POST /api/ops/v1/finance/sources/aws/sync`,
~$0.03 per call), the snapshots are queryable from cached storage:

```bash
# MTD spend by AWS service (Lambda, DynamoDB, ...)
curl /api/ops/v1/finance/costs/aws

# MTD spend by Domain tag (social, decks, srs, ...)
curl /api/ops/v1/finance/costs/by-domain
```

The sync writes to SQLite locally / DynamoDB in prod; reads are free
and fast. **Never call Cost Explorer from a request path** — every CE
call is ~$0.01 and a busy request loop will burn budget on metering
the budget.

## When the tag set changes

If you add a new table:

1. Add the table in `main.tf` with `tags = merge(local.common_tags, { Domain = "<your-domain>" })`.
2. If the domain value is **new** (not already in the table above), also:
   - Add it to the table above.
   - Add it to `_KNOWN_DOMAINS` in
     `lingo-ops/app/finance/router.py` so the `/costs/by-domain`
     response keeps a stable shape.
   - Re-activate is NOT needed (the tag key is already active).

If you rename a `Domain` value, expect a one-month gap in the rollup
for the old value as historic billing data still references the old
tag string. CE doesn't backfill renames.
