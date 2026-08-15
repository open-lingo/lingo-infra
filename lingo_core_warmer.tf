# ---------------------------------------------------------------------------
# Keep-warm ping for the lingo-core Lambda.
# ---------------------------------------------------------------------------
# Why (measured 2026-08-15): a cold start costs ~2.4–2.9 s and the app's boot
# used to fan out six concurrent requests — six cold instances on the day's
# first open. The frontend now batches boot into one GET /boot request, and
# this rule keeps one instance initialized so that request is usually warm
# too. app/handler.py in lingo-core short-circuits the {"warmer": true}
# payload before Mangum ever sees it.
#
# Cost, quantified: rate(4 minutes) ≈ 10.8k invocations/month × ~1 ms billed
# ≈ $0.01/mo — versus provisioned concurrency at ~$5.50/mo per 512 MB unit.
# One warm instance does NOT absorb concurrent bursts; if boot ever fans out
# again, revisit provisioned concurrency instead of adding more pings.

resource "aws_cloudwatch_event_rule" "lingo_core_warmer" {
  name                = "lingo-core-warmer"
  description         = "Keep one lingo-core Lambda instance initialized"
  schedule_expression = "rate(4 minutes)"
}

resource "aws_cloudwatch_event_target" "lingo_core_warmer" {
  rule  = aws_cloudwatch_event_rule.lingo_core_warmer.name
  arn   = aws_lambda_function.lingo_core.arn
  input = jsonencode({ warmer = true })
}

resource "aws_lambda_permission" "lingo_core_warmer" {
  statement_id  = "AllowWarmerEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lingo_core.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lingo_core_warmer.arn
}
