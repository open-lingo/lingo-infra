# ---------------------------------------------------------------------------
# GitHub Actions CI roles via OIDC — replaces the lingo-deploy IAM user.
# ---------------------------------------------------------------------------
# This is the migration the lingo-deploy block (bottom of main.tf) flagged as
# its own tripwire: short-lived OIDC credentials, one role per repo, scoped to
# only that repo's deploy verbs — instead of one shared admin user whose static
# keys live in GitHub org secrets.
#
# The OIDC identity provider itself is account-global and owned by the
# shared-infra repo (lichfiet/shared-infra); apply that first.
#
# Cutover plan (per repo): switch its deploy.yml to role-to-assume, confirm a
# green deploy, then delete the lingo-deploy user + Secrets Manager secret from
# main.tf and remove the org secrets from GitHub.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

locals {
  lambda_arn_prefix = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function"

  # repo => config. Trust is scoped to main-branch pushes in the open-lingo org.
  ci_lambda_repos = {
    "lingo-core" = {
      # Currently deploys the manually-provisioned 'lingo-test'; will become
      # 'lingo-core' when that function moves under Terraform.
      function_arns = [
        "${local.lambda_arn_prefix}:lingo-test",
        "${local.lambda_arn_prefix}:lingo-core",
      ]
    }
    "lingo-ops" = {
      function_arns = [aws_lambda_function.lingo_ops.arn]
    }
    "lingo-async" = {
      function_arns = [aws_lambda_function.lingo_async.arn]
    }
  }
}

# --- Trust policies (one per repo, main branch only) --------------------------

data "aws_iam_policy_document" "ci_trust" {
  for_each = merge(local.ci_lambda_repos, { "lingo" = {} })

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:open-lingo/${each.key}:ref:refs/heads/main"]
    }
  }
}

# --- Lambda deploy roles (lingo-core, lingo-ops, lingo-async) -----------------

data "aws_iam_policy_document" "ci_lambda_permissions" {
  for_each = local.ci_lambda_repos

  statement {
    sid    = "DeployLambdaCode"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:InvokeFunction", # post-deploy smoke tests
    ]
    resources = each.value.function_arns
  }
}

resource "aws_iam_role" "ci_lambda" {
  for_each = local.ci_lambda_repos

  name                 = "ci-${each.key}"
  description          = "GitHub Actions CI role for open-lingo/${each.key} (deploys Lambda code)"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust[each.key].json
  max_session_duration = 3600

  tags = { Domain = "ops" }
}

resource "aws_iam_role_policy" "ci_lambda" {
  for_each = local.ci_lambda_repos

  name   = "ci-${each.key}-permissions"
  role   = aws_iam_role.ci_lambda[each.key].id
  policy = data.aws_iam_policy_document.ci_lambda_permissions[each.key].json
}

# --- Web deploy role (lingo repo → S3 sync + CloudFront invalidation) ---------

data "aws_iam_policy_document" "ci_web_permissions" {
  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  statement {
    sid    = "SyncSiteObjects"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  statement {
    sid       = "InvalidateCdn"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }
}

resource "aws_iam_role" "ci_web" {
  name                 = "ci-lingo-web"
  description          = "GitHub Actions CI role for open-lingo/lingo (deploys static site)"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust["lingo"].json
  max_session_duration = 3600

  tags = { Domain = "web" }
}

resource "aws_iam_role_policy" "ci_web" {
  name   = "ci-lingo-web-permissions"
  role   = aws_iam_role.ci_web.id
  policy = data.aws_iam_policy_document.ci_web_permissions.json
}

# --- Outputs -------------------------------------------------------------------

output "ci_role_arns" {
  description = "Per-repo CI role ARNs. Set each as role-to-assume in that repo's deploy workflow."
  value = merge(
    { for k, r in aws_iam_role.ci_lambda : k => r.arn },
    { "lingo" = aws_iam_role.ci_web.arn },
  )
}
