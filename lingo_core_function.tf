# ── lingo-core Lambda (the main API) ──────────────────────────────────────────
#
# Replaces the manually-provisioned `lingo-test` function. Same split as
# lingo-ops / lingo-async: Terraform owns infra (role, function, URL, env
# structure); the lingo-core repo's deploy workflow owns code via
# `aws lambda update-function-code`.
#
# Bootstrap: created from a placeholder zip — the function 500s until the
# first CI deploy lands real code (trigger the lingo-core `deploy` workflow
# right after `terraform apply`).

variable "lingo_core_zip_path" {
  description = "Path to a Lambda zip used ONLY at creation (CI owns code afterwards). Defaults to the placeholder."
  type        = string
  default     = "lambda_placeholder.zip"
}

# Trust policy: only Lambda can assume this role.
data "aws_iam_policy_document" "lingo_core_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lingo_core_lambda" {
  name               = "lingo-core-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lingo_core_lambda_assume.json
  tags               = { Domain = "core" }
}

resource "aws_iam_role_policy_attachment" "lingo_core_basic_exec" {
  role       = aws_iam_role.lingo_core_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# lingo-core touches every product table (users, srs, decks, progress, social,
# community, …) — everything except lingo_jobs (lingo-ops only).
locals {
  lingo_core_tables = [
    aws_dynamodb_table.users,
    aws_dynamodb_table.subscriptions,
    aws_dynamodb_table.srs,
    aws_dynamodb_table.decks,
    aws_dynamodb_table.progress,
    aws_dynamodb_table.social,
    aws_dynamodb_table.social_leaderboard,
    aws_dynamodb_table.deck_votes,
    aws_dynamodb_table.tags,
    aws_dynamodb_table.community_threads,
    aws_dynamodb_table.community_posts,
    aws_dynamodb_table.community_votes,
    aws_dynamodb_table.community_addons,
    aws_dynamodb_table.community_markdown,
  ]
}

data "aws_iam_policy_document" "lingo_core_lambda_extras" {
  # Product tables — full CRUD including GSIs.
  statement {
    sid = "ProductTablesCRUD"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
    ]
    resources = concat(
      [for t in local.lingo_core_tables : t.arn],
      [for t in local.lingo_core_tables : "${t.arn}/index/*"],
    )
  }

  # Publish async events (kombu SQS transport) to the lingo-events queue.
  statement {
    sid = "EventsPublish"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.lingo_events.arn]
  }

  # kombu's SQS transport lists queues by prefix on connection setup.
  statement {
    sid       = "EventsQueueDiscovery"
    actions   = ["sqs:ListQueues"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lingo_core_lambda_extras" {
  name        = "lingo-core-lambda-extras"
  description = "Product-table CRUD + lingo-events SQS publish for the lingo-core Lambda."
  policy      = data.aws_iam_policy_document.lingo_core_lambda_extras.json
  tags        = { Domain = "core" }
}

resource "aws_iam_role_policy_attachment" "lingo_core_extras" {
  role       = aws_iam_role.lingo_core_lambda.name
  policy_arn = aws_iam_policy.lingo_core_lambda_extras.arn
}

resource "aws_lambda_function" "lingo_core" {
  function_name = "lingo-core"
  role          = aws_iam_role.lingo_core_lambda.arn
  handler       = "app.handler.handler"
  runtime       = "python3.13"
  # x86_64 (not arm64): lingo-core's build-zip.sh installs runner-native wheels
  # (cryptography et al.) and CI runners are x86_64.
  architectures = ["x86_64"]
  memory_size   = 512
  timeout       = 30

  filename         = var.lingo_core_zip_path
  source_code_hash = filebase64sha256(var.lingo_core_zip_path)

  environment {
    # Initial values; secrets (INTERNAL_SERVICE_TOKEN) get set via console.
    # The lifecycle block below stops Terraform from clobbering them later.
    variables = {
      DB_BACKEND             = "dynamodb"
      DYNAMODB_TABLE_PREFIX  = var.table_prefix
      AUTH0_DOMAIN           = "dev-txjdn01ew3dmaecy.us.auth0.com"
      AUTH0_AUDIENCE         = "openlingodev"
      ADMIN_USER_IDS         = "[]"
      INTERNAL_SERVICE_TOKEN = ""
      CORS_ORIGINS           = "[\"http://localhost:5173\", \"https://openlingoapp.com\", \"https://www.openlingoapp.com\"]"
      EVENTS_BROKER_URL      = "sqs://"
      DEBUG                  = "false"
    }
  }

  lifecycle {
    # CI owns code (source_code_hash/filename); console owns secret env values.
    ignore_changes = [
      environment[0].variables,
      source_code_hash,
      filename,
    ]
  }

  tags = { Domain = "core" }
}

# Function URL — public HTTPS endpoint, no API Gateway.
# CORS is handled by the app itself (CORS_ORIGINS env var → FastAPI middleware),
# matching how lingo-test behaved. No URL-level CORS to avoid double headers.
resource "aws_lambda_function_url" "lingo_core" {
  function_name      = aws_lambda_function.lingo_core.function_name
  authorization_type = "NONE" # App handles auth via Auth0 JWT.
}

output "lingo_core_function_name" {
  value = aws_lambda_function.lingo_core.function_name
}

output "lingo_core_url" {
  description = "Public Lambda URL for the lingo-core API. Set as VITE_API_BASE_URL in the lingo repo."
  value       = aws_lambda_function_url.lingo_core.function_url
}
