# ── Keep-warm pings for lingo-core + lingo-ops Lambdas ───────────────────────
#
# AWS Lambda spins down idle containers after ~5–15 min, so the next request
# eats a cold-start penalty (Python 3.13 + Mangum + all our deps initialize:
# ~1.5–3s end-to-end). For an interactive web app that's a felt slowness on
# the first click after a quiet stretch.
#
# Two cheap mitigations exist:
#   1. Provisioned concurrency — guarantees N warm containers but costs
#      ~$10/mo per concurrency unit per function. Overkill for our scale.
#   2. Scheduled "ping" invocations — fires every 5 min, keeps at least
#      one container hot. Costs ~$0.0000002/invocation × 12/hour × 24h ×
#      30d × 2 functions ≈ pennies/month. Acceptable trade-off for the
#      MVP scale we're at.
#
# This file implements option (2): an EventBridge schedule that invokes
# both Lambdas every 5 minutes with a synthetic /health payload Mangum
# recognizes as a Function-URL GET request. The app's /health route is
# unauthenticated and returns 200 quickly without touching the database.
#
# When traffic scales up enough that organic load keeps the containers
# warm anyway, this can be removed without code changes.

# ─── EventBridge rule (5 min cadence) ───────────────────────────────────────

resource "aws_cloudwatch_event_rule" "lambda_keep_warm" {
  name                = "lingo-lambda-keep-warm"
  description         = "Ping lingo-core + lingo-ops every 5 min so cold-start tax doesn't hit the first interactive click."
  schedule_expression = "rate(5 minutes)"
  tags                = { Domain = "ops" }
}

# Synthetic Function-URL payload. Mangum looks at the v2 HTTP-API envelope
# and routes to the FastAPI app; the /health route is unauthenticated and
# returns immediately so the keep-warm path stays cheap.
locals {
  keep_warm_payload = jsonencode({
    version        = "2.0"
    routeKey       = "$default"
    rawPath        = "/health"
    rawQueryString = ""
    headers = {
      host       = "keep-warm.lingo.internal"
      user-agent = "lingo-keep-warm/1.0"
    }
    requestContext = {
      accountId    = "anonymous"
      apiId        = "keep-warm"
      domainName   = "keep-warm.lingo.internal"
      domainPrefix = "keep-warm"
      http = {
        method    = "GET"
        path      = "/health"
        protocol  = "HTTP/1.1"
        sourceIp  = "127.0.0.1"
        userAgent = "lingo-keep-warm/1.0"
      }
      requestId = "keep-warm"
      routeKey  = "$default"
      stage     = "$default"
      time      = "00:00:00"
      timeEpoch = 0
    }
    isBase64Encoded = false
  })
}

# ─── Target: lingo-core ─────────────────────────────────────────────────────

resource "aws_cloudwatch_event_target" "lingo_core_keep_warm" {
  rule      = aws_cloudwatch_event_rule.lambda_keep_warm.name
  target_id = "lingo-core"
  arn       = aws_lambda_function.lingo_core.arn
  input     = local.keep_warm_payload
}

resource "aws_lambda_permission" "lingo_core_keep_warm" {
  statement_id  = "EventBridgeKeepWarmInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lingo_core.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_keep_warm.arn
}

# ─── Target: lingo-ops ──────────────────────────────────────────────────────

resource "aws_cloudwatch_event_target" "lingo_ops_keep_warm" {
  rule      = aws_cloudwatch_event_rule.lambda_keep_warm.name
  target_id = "lingo-ops"
  arn       = aws_lambda_function.lingo_ops.arn
  input     = local.keep_warm_payload
}

resource "aws_lambda_permission" "lingo_ops_keep_warm" {
  statement_id  = "EventBridgeKeepWarmInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lingo_ops.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_keep_warm.arn
}
