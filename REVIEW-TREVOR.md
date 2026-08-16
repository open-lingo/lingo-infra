# Trevor: backend/AWS review queue — 2026-08-15

Left by the load-time optimization work (Spencer's ask). Agent machines have
no AWS creds, so everything below needs your hands. Delete this file (or
strike items) as you clear it. Full measurement context lives in
`lingo/docs/perf-followups-2026-08-15.md`.

State is local (`terraform.tfstate` on the machine that applies), so run
`terraform plan` first and expect the two warmer resources + one lambda
permission as the only adds.

## 1. `terraform apply` the Lambda warmer — DO THIS ONE FIRST

`lingo_core_warmer.tf` (commit `6d17bc1`) is written but **not applied**.
EventBridge `rate(4 minutes)` → lingo-core with `{"warmer": true}`; the
handler short-circuit already shipped and is live in prod (lingo-core
`eba61b0`), so applying is safe in either order.

- Impact: the day's first `/api/core/v1/boot` currently pays a ~2.6 s cold
  start; warm path is 0.9–1.5 s. This is the single biggest remaining lever.
- Cost: ~$0.01/mo (≈10.8k no-op invokes) vs ~$5.50/mo for provisioned
  concurrency.

## 2. CloudWatch: explain the ~570 ms warm floor

`GET /health` (no auth, no DB) measured ~570 ms TTFB **on a reused TLS
connection**. The access-log middleware prints server-side ms to CloudWatch.
If those logs show single-digit ms, ~half a second per request is burning in
the function-URL/invoke path (WAF? payload buffering?) — and *every* API
call pays it. Needs someone with CloudWatch access to read the logs; no
change proposed yet, just attribution.

## 3. CloudFront drift: the app distribution is in NO .tf file

`app.openlingoapp.com` (the actual app) is served by a distribution that
does not exist in this repo. `static_site.tf`'s comments/claims about the
apex are stale — apex is the marketing site now. Please either
`terraform import` the app distro or at minimum document its ID here.
This blocks item 4 and is a "which distro am I editing?" hazard —
**do not edit the apex distro** for app concerns.

## 4. Short-TTL cache policy for the app's `index.html`

Blocked on item 3. The shell is `no-cache` today — `x-cache: Miss` on every
request, ~0.5–0.7 s of origin round trip for first-time / service-worker-less
visitors. A 60–300 s TTL (or stale-while-revalidate) is safe: the deploy
workflow already invalidates `/index.html`, `/`, `/sw.js`,
`/manifest.webmanifest` on every push.

## 5. Optional: lingo-core Lambda 512 → 1024 MB

Likely halves the ~2.6 s cold init for single-digit $/mo. Mostly moot once
the warmer (item 1) is applied — skip unless colds stay visible.

## FYI — already live, no action, but you should know

- **lingo-core** now serves `GET /api/core/v1/boot` batching the six boot
  reads (user/settings/progress/unlocks/touch/srs + best-effort
  quests/subscriptions) into one invoke. Six parallel cold starts at
  2.4–2.9 s each became one call. Candidate next fold-in: `decks/batch`.
- **lingo web deploy** now publishes staged audio: `lingo/tts-publish/*.mp3`
  → `s3://<site bucket>/tts/v1/` via the existing `ci-lingo-web` role (it
  already had bucket-wide write). Append-only, no `--delete`, corpus-count
  assert still guards the bucket. Rationale in `lingo/tts-publish/README.md`
  (short version: the M31 wave shipped manifest hashes whose mp3s were still
  local-only — every new clip served the SPA shell as `text/html`).
- The handler rewrite for the warmer (`lingo-core/app/handler.py`) is
  deployed and passing in prod.
