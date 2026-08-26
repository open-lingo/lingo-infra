# App Store beta — infra asks for Trevor (2026-08-26)

We're taking the iOS app public on the App Store (rebranded **Linguiversal**,
bundle `com.linguiversal.app`). Before that happens, four infra changes shrink
the abuse ceiling from ~$720/day to ~$14/day and cut the unauthenticated API
surface from 9 endpoints to 1. Everything code-side is already merged; these
are the AWS-side pieces.

Background reading (both pushed):

- Full launch checklist + exposure audit: `lingo/docs/app-store-launch-readiness-2026-08-20.md`
- Pen-test writeup: `lingo-core/docs/security-pentest-2026-08-20.md`

## What's exposed today

- **Both Lambda Function URLs are raw public** (`authorization_type = "NONE"`):
  no CloudFront in the request path, no WAF, no rate limiting, **no reserved
  concurrency**. Every request — even a garbage 401 — bills Lambda time.
- **9 unauthenticated endpoints**, including 6 `/community/*` + `/tags` reads
  that each run DynamoDB **paginated full-table scans** with a per-thread N+1.
  Cost grows with table size; no account needed.
- **Admin routes have no role enforcement yet** — any authenticated user can
  hit them until the surface-mode change below un-mounts them.
- Worst case (512 MB, x86): an attacker holding the account's full 1,000
  concurrency at the 30 s timeout ≈ **$720/day** of Lambda spend *and* starves
  the shared pool the async/TTS pipeline runs on. A dumber 1k req/s junk-401
  flood is ~$25–30/day Lambda + ~$7/day CloudWatch log ingest.

## The asks, cheapest first

1. **`reserved_concurrent_executions = 20`** on lingo-core, **~5** on
   lingo-ops — one line each in tf. Converts the $720/day ceiling into
   ~$14/day and firewalls the async pipeline's concurrency. Sizing: real
   traffic today is one warm instance, so 20 is >10× headroom.
2. **AWS Budgets alerts** at $10 and $25/mo (email Spencer + Trevor) +
   CloudWatch alarms on `ConcurrentExecutions` and 4xx rate. Budgets are
   free — this is the "find out in hours, not on the bill" control.
3. **WAF on the `app.openlingoapp.com` CloudFront distro**: verify the shared
   WAF is attached and add a rate-based rule (~2,000 req/5min/IP). ⚠️ That
   distro is **not in terraform** (known drift — it was created outside tf;
   `static_site.tf`'s apex claims don't cover it), so this is a console/import
   job, not a plain tf edit.
4. **Set `SURFACE_MODE=beta` on the deployed lingo-core Lambda.** The code
   shipped in lingo-core `5c5241e` (deployed with the 2026-08-26 push); the
   env var is the switch. Terraform deliberately ignores Lambda env vars
   (`lifecycle ignore_changes`) and the deploy workflow only updates code, so
   this is a one-time
   `aws lambda update-function-configuration --function-name <fn> --environment ...`
   preserving the existing vars. Effect: only boot/users/srs/progress stay
   HTTP-mounted — unauthenticated surface drops 9 → 1 (`/health`), and the
   un-gated admin routers stop being reachable at all. Unknown/unset values
   fail open to `full`, so a typo can't blank the API.

Items 1–3 mirror §3 of the launch-readiness doc; item 4 is the pen-test's
landed fix waiting on its env var. Questions → Spencer, or the two docs above.
