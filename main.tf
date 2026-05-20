# DynamoDB tables for lingo-core (users, subscriptions, SRS, decks)
# Set AWS credentials and run: terraform init && terraform apply

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "table_prefix" {
  description = "Prefix for DynamoDB table names (matches DYNAMODB_TABLE_PREFIX in lingo-core)"
  type        = string
  default     = "lingo_"
}

variable "aws_region" {
  description = "AWS region for DynamoDB tables"
  type        = string
  default     = "us-west-1"
}

provider "aws" {
  region = var.aws_region
}

# ── Users ─────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "users" {
  name         = "${var.table_prefix}users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }
  attribute {
    name = "GSI2PK"
    type = "S"
  }
  attribute {
    name = "GSI2SK"
    type = "S"
  }

  global_secondary_index {
    name               = "Auth0-Index"
    hash_key           = "GSI1PK"
    range_key          = "GSI1SK"
    projection_type    = "INCLUDE"
    non_key_attributes = ["id"]
  }

  global_secondary_index {
    name            = "Username-Index"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "ALL"
  }
}

# ── Subscriptions (user content subscriptions: decks, addons, stories) ─────────

resource "aws_dynamodb_table" "subscriptions" {
  name         = "${var.table_prefix}subscriptions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
}

# ── SRS (per-user card state) ─────────────────────────────────────────────────

resource "aws_dynamodb_table" "srs" {
  name         = "${var.table_prefix}srs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "user_id"
    type = "S"
  }
  attribute {
    name = "dueDate"
    type = "S"
  }

  global_secondary_index {
    name            = "DueDate-Index"
    hash_key        = "user_id"
    range_key       = "dueDate"
    projection_type = "ALL"
  }
}

# ── Decks ─────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "decks" {
  name         = "${var.table_prefix}decks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "languageId"
    type = "S"
  }
  attribute {
    name = "authorId"
    type = "S"
  }
  attribute {
    name = "authorUpdatedDeck"
    type = "S"
  }

  global_secondary_index {
    name            = "StatusLanguage-Index"
    hash_key        = "status"
    range_key       = "languageId"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "AuthorUpdated-Index"
    hash_key        = "authorId"
    range_key       = "authorUpdatedDeck"
    projection_type = "ALL"
  }
}

# ── Progress (per-attempt log + lesson/day/concept rollups) ───────────────────
# See lingo-core/docs/adr/0001-progress-api-hybrid-rollup.md for the design.
# Single-table per user (PK = USER#<id>), four SK shapes:
#   ATTEMPT#<lessonId>#<isoTs>  — immutable per-attempt log
#   LESSON#<lessonId>           — eager best-score rollup
#   DAY#<YYYY-MM-DD>            — eager daily activity rollup
#   CONCEPT#<conceptId>         — lazy-materialized mastery rollup
#
# user_id + attemptedAt power the UserAttempts-Index GSI (sparse — only ATTEMPT
# rows write to it). Used for recent-attempts feeds and lazy concept recompute.
# Streak / XP / lingots live on the existing users table, not here.

resource "aws_dynamodb_table" "progress" {
  name         = "${var.table_prefix}progress"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "user_id"
    type = "S"
  }
  attribute {
    name = "attemptedAt"
    type = "S"
  }

  global_secondary_index {
    name            = "UserAttempts-Index"
    hash_key        = "user_id"
    range_key       = "attemptedAt"
    projection_type = "ALL"
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "users_table_name" {
  value = aws_dynamodb_table.users.name
}

output "subscriptions_table_name" {
  value = aws_dynamodb_table.subscriptions.name
}

output "srs_table_name" {
  value = aws_dynamodb_table.srs.name
}

output "decks_table_name" {
  value = aws_dynamodb_table.decks.name
}

output "progress_table_name" {
  value = aws_dynamodb_table.progress.name
}
