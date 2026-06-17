# ── CloudWatch log retention ──────────────────────────────────────────────────
#
# Lambda auto-creates its /aws/lambda/<name> log group on first invocation with
# retention set to "Never expire" (the only unbounded-growth cost in the stack —
# logs otherwise accumulate forever). Declaring the groups explicitly pins a
# 30-day retention.
#
# ADOPTION: these groups almost certainly ALREADY EXIST (Lambda created them at
# never-expire). A CloudWatch log group is keyed solely by name, so a plain
# `terraform apply` of a same-named group will FAIL with "already exists" unless
# the existing group is first adopted:
#
#   terraform import aws_cloudwatch_log_group.lingo_core  /aws/lambda/lingo-core
#   terraform import aws_cloudwatch_log_group.lingo_ops   /aws/lambda/lingo-ops
#   terraform import aws_cloudwatch_log_group.lingo_async /aws/lambda/lingo-async
#
# After import, apply reconciles retention_in_days + tags onto the live group.
#
# STALE GROUP: /aws/lambda/lingo-test (the pre-Terraform function name still
# referenced in ci_oidc.tf) is NOT managed here. Delete it manually once the
# lingo-test function is fully retired:
#   aws logs delete-log-group --log-group-name /aws/lambda/lingo-test
# (or import it here and `terraform state rm` + delete, if you prefer adopt-then-
# remove). Left out of Terraform on purpose — it tracks a function this repo
# does not own.

resource "aws_cloudwatch_log_group" "lingo_core" {
  name              = "/aws/lambda/${aws_lambda_function.lingo_core.function_name}"
  retention_in_days = 30

  tags = { Domain = "core" }
}

resource "aws_cloudwatch_log_group" "lingo_ops" {
  name              = "/aws/lambda/${aws_lambda_function.lingo_ops.function_name}"
  retention_in_days = 30

  tags = { Domain = "ops" }
}

resource "aws_cloudwatch_log_group" "lingo_async" {
  name              = "/aws/lambda/${aws_lambda_function.lingo_async.function_name}"
  retention_in_days = 30

  tags = { Domain = "async" }
}
