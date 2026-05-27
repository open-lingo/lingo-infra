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

variable "environment" {
  description = "Deployment environment (dev / staging / prod) — surfaced as a tag on newly-provisioned tables."
  type        = string
  default     = "dev"
}

provider "aws" {
  region = var.aws_region
}

# Standard tag set applied to every table. The `Domain` tag is per-table
# (merged in via `merge(local.common_tags, { Domain = "<domain>" })` on
# each resource) so AWS Cost Explorer can break spend down by domain —
# powers /api/ops/v1/finance/costs/by-domain in lingo-ops.
#
# Cost allocation tags become queryable only after a one-time activation
# in the AWS Billing console (Cost allocation tags → Activate `Project`,
# `Environment`, `Domain`), with ~24h propagation. See docs/cost-tags.md.
locals {
  common_tags = {
    Project     = "open-lingo"
    Environment = var.environment
  }
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

  tags = merge(local.common_tags, { Domain = "users" })
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

  # Subscriptions belong to the user domain (each row is owned by a user
  # and the only access pattern is user-scoped). Bucketing under "users"
  # keeps the Cost Explorer rollup matching the bill-mental-model rather
  # than the storage-layout-mental-model.
  tags = merge(local.common_tags, { Domain = "users" })
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

  tags = merge(local.common_tags, { Domain = "srs" })
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

  tags = merge(local.common_tags, { Domain = "decks" })
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

  tags = merge(local.common_tags, { Domain = "progress" })
}

# ── Social (friends, requests, blocks, activity, invites, threads) ────────────
#
# Mirrors the single-table layout documented in lingo-core
# app/db/dynamo/social.py — that file is the source of truth for the key
# shapes below. The DynamoSocialRepository methods write/read these exact
# patterns; **do not change PK/SK conventions here without updating that
# module first**.
#
# Status: the Dynamo repo is wired but the production handler currently
# falls back to the SQLite-first impl. Provisioning this ahead of the cut-
# over so the table is ready when the switch flips. — 2026-05-25
#
# Key layout:
#   PK = USER#<id>             SK = FRIEND#<friend_id>
#   PK = USER#<id>             SK = REQUEST_IN#<from_id>
#   PK = USER#<id>             SK = REQUEST_OUT#<to_id>
#   PK = USER#<id>             SK = BLOCK#<blocked_id>
#   PK = USER#<id>             SK = ACTIVITY#<created_at>#<activity_id>
#   PK = USER#<id>             SK = THREAD#<thread_id>
#   PK = ACTIVITY#<id>         SK = META
#   PK = ACTIVITY#<id>         SK = REACTION#<id>#<kind>#<user_id>
#   PK = INVITE#<code>         SK = META
#   PK = INVITE#<code>         SK = REDEMPTION#<invitee_id>
#   PK = INVITE_OWNER#<owner>  SK = META
#   PK = INVITER#<owner>       SK = REDEMPTION#<year_month>#<invitee_id>
#   PK = THREAD#<id>           SK = META
#   PK = THREAD#<id>           SK = MESSAGE#<sent_at>#<message_id>
#
# Access patterns + decision log:
#   1. list_friends(user)               → Query PK=USER#u, SK begins_with FRIEND#
#   2. list_friend_requests(user)       → 2x Query PK=USER#u, REQUEST_IN# / REQUEST_OUT#
#   3. is_friend / get_request / is_blocked / get_block → GetItem on exact (PK,SK)
#   4. add_friend_edge                   → 2x PutItem (reciprocal — both users get a row)
#   5. list_activity(user, friends)      → fan-out Query per uid, SK begins_with ACTIVITY#
#   6. get_activity / list_reactions     → GetItem / Query under PK=ACTIVITY#id
#   7. invite by code                    → GetItem PK=INVITE#code, SK=META
#   8. invite by owner                   → GetItem PK=INVITE_OWNER#owner, SK=META
#   9. monthly redemption cap            → Query PK=INVITER#owner, SK begins_with REDEMPTION#YYYY-MM#
#  10. list_threads_for_user             → Query PK=USER#u, SK begins_with THREAD#
#  11. list_messages(thread)             → Query PK=THREAD#id, SK begins_with MESSAGE#
#
# GSIs: NONE.
#   The repo intentionally writes reciprocal rows (friend edges go to both
#   users; invite redemptions get mirrored to INVITER#<owner> so the monthly
#   cap query is bounded). Every read path resolves to a (PK, SK) Query or
#   GetItem. There is no "who's blocked me?" route in the protocol — adding
#   an inverse-BLOCK GSI now would burn WCU on every block write for no read.
#
# TTL: NONE for now. Activity items + DM messages have no expiry in the
#   protocol today and routers may scroll back arbitrarily far.

resource "aws_dynamodb_table" "social" {
  name         = "${var.table_prefix}social"
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

  tags = merge(local.common_tags, { Domain = "social" })
}

# ── Social leaderboard (per-bucket XP ranking) ────────────────────────────────
#
# Kept SEPARATE from lingo_social on purpose:
#   - Write rate is much higher (every lesson batch that earns XP from every
#     opted-in user fires one UpdateItem here, partitioned by language+period).
#     Co-tenanting with lingo_social spreads heat across one partition space
#     and complicates eventual TTL/migration of one without the other.
#   - The data is ephemeral (TTL after period close) — lingo_social rows are
#     long-lived.
#
# Bucket scheme (matches scripts/seed.py + app/progress/router.py):
#   weekly:  "{lang_id}#{YYYY}-W{ww}"          e.g. "ja#2026-W21"
#   monthly: "{lang_id}#{YYYY}-{MM}"           e.g. "ja#2026-05"
#
# Key layout:
#   PK = BUCKET#<bucket_str>     SK = USER#<user_id>
#
# Access patterns + decision log:
#   1. add_xp_to_leaderboard(user, lang, xp)
#       → UpdateItem PK=BUCKET#x, SK=USER#me, ADD xp :inc, SET ttl=<epoch>
#       (wired in app/progress/router.py; Dynamo impl pending)
#   2. get my row for a bucket → GetItem (PK, SK)
#   3. top-N for a bucket      → NOT YET WIRED. Current /social/leaderboards/*
#      endpoints compute rankings on-the-fly from progress rollups; they
#      don't read this table. When the read switches to query this table,
#      add a GSI:
#          GSI1PK = "PK" (i.e. BUCKET#x)   GSI1SK = "xp" (N)
#      and Query ScanIndexForward=false for top-N. Skipping it now avoids
#      paying WCU amplification on every leaderboard write for a read path
#      no code exercises. **Add the GSI in the same commit that switches
#      the read path** — not earlier.
#
# TTL: enabled on attribute "ttl" (epoch seconds). Producer (Python) is
#   expected to set ttl = bucket_end + 30 days grace so historical buckets
#   self-purge per [[project-social-design]] (30-day retention on inactivity).
#   Empty/null ttl rows are NOT auto-deleted — only rows with a numeric ttl
#   in the past get reaped. Backfill writes that omit ttl persist forever,
#   which is the safe default.

resource "aws_dynamodb_table" "social_leaderboard" {
  name         = "${var.table_prefix}social_leaderboard"
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

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, { Domain = "social" })
}

# ── Deck votes (per-user upvotes on community decks) ──────────────────────────
#
# Kept SEPARATE from lingo_decks on purpose:
#   - lingo_decks has two GSIs (StatusLanguage-Index, AuthorUpdated-Index)
#     that vote rows would have to pay WCU into on every vote write, for
#     zero read benefit (no listing route filters/sorts by vote).
#   - Deck content items are large (cards JSON serialised inline); vote
#     rows are tiny. Mixing item sizes in one partition muddies hot-key
#     diagnostics.
#   - Deletes of a deck need to cascade through votes; doing that in a
#     dedicated table is a straightforward Query+BatchWriteItem loop.
#
# **Status: NOT YET IMPLEMENTED in app/db/dynamo/deck.py.** The vote
# methods there raise NotImplementedError per maintainer instruction
# (SQLite-first; Dynamo lands after the SQLite path validates). This
# Terraform exists so the table is provisioned before that cut-over so the
# implementer doesn't get blocked on infra.
#
# Mirrors the SQLite shape in app/db/sqlite/deck.py (deck_votes:
# PRIMARY KEY (deck_id, user_id), index on (deck_id)).
#
# Key layout:
#   PK = DECK#<deck_id>     SK = USER#<user_id>
#   attrs: deck_id, user_id, created_at
#
# Access patterns + decision log:
#   1. add_vote(deck, user)    → PutItem (idempotent — same key overwrites)
#   2. remove_vote(deck, user) → DeleteItem
#   3. get_vote_state(deck, user)
#       → GetItem (PK, SK) for "voted?", plus get_vote_count for "count"
#   4. get_vote_count(deck)    → Query PK=DECK#d, Select=COUNT
#   5. get_vote_counts([decks]) → N parallel queries (page-sized N, fine
#      on-demand). If this becomes hot, materialize a counter on the deck
#      item itself in lingo_decks via UpdateItem ADD voteCount :1 — but
#      don't pre-build that until /decks list responses start dominating
#      vote-count cost.
#
# GSIs: NONE.
#   No route lists "decks user X voted on" — adding a USER#u → DECK#d
#   inverse GSI would burn WCU per vote for an unused read.
#
# TTL: NONE. Votes are persistent.

resource "aws_dynamodb_table" "deck_votes" {
  name         = "${var.table_prefix}deck_votes"
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

  tags = merge(local.common_tags, { Domain = "decks" })
}

# ── Community (forum threads, posts, addons, markdown KV) ────────────────────
#
# Pre-provisioned for the future Dynamo cut-over. The app currently uses
# SqliteCommunityRepository for `DB_BACKEND=sqlite` and falls back to the
# in-memory MockCommunityRepository for `DB_BACKEND=dynamodb` until
# app/db/dynamo/community.py is implemented — these tables exist so the
# implementer doesn't get blocked on infra.
#
# We split into 5 tables instead of one because the access patterns and item
# shapes diverge sharply (small vote rows vs. large markdown blobs vs. heavily
# queried thread metadata). Mixing them in a single table would complicate
# hot-key diagnostics and force a wider attribute schema than each domain
# needs.
#
# Tag and category lookup live next to threads (small dimension tables, low
# read traffic). The SQLite impl seeds the 5 default categories on first
# connect; the Dynamo cut-over should do the same with a one-shot
# PutItem-if-not-exists batch on first boot.

# Threads — primary forum surface. Listing by category is the hot path.
#
#   PK = THREAD#<thread_id>          SK = META
#   GSI1PK = "CATEGORY#<id>"         GSI1SK = "<updated_at>"  (newest-first list)
#
# Access patterns:
#   1. create_thread / get_thread_by_id / update_thread / increment_views
#       → PutItem / GetItem / UpdateItem on (PK, SK)
#   2. list_threads(category_id, sort='new')
#       → Query GSI1PK=CATEGORY#<id>, ScanIndexForward=false
#   3. list_threads(category_id, sort='hot')
#       → Query GSI1 then sort client-side; full re-rank in Lambda is fine
#         at forum scale (low write rate, modest pages).
#   4. list_threads(tag_id=...) / list_threads(content_type=...)
#       → Read from the junction tables (lingo_community_thread_tags is the
#         SQLite shape; in Dynamo the same data is stored as separate rows on
#         the same thread item under SK = TAG#<tag_id> / CONTENT#<type>#<id>
#         once the impl lands — no separate table needed).
#
# GSI choice: ONE GSI (CategoryUpdated-Index). Tag/content filters are rare
#   enough to do a client-side filter on the category result set. If a query
#   pattern needs sub-second tag filtering later, add a TagUpdated-Index then,
#   not now.

resource "aws_dynamodb_table" "community_threads" {
  name         = "${var.table_prefix}community_threads"
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

  global_secondary_index {
    name            = "CategoryUpdated-Index"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  tags = merge(local.common_tags, { Domain = "community" })
}

# Posts (thread replies). Listed strictly by thread, oldest-first.
#
#   PK = THREAD#<thread_id>     SK = POST#<created_at>#<post_id>
#
# Access patterns:
#   1. create_post                          → PutItem (also UpdateItem the
#                                              parent thread reply_count + ts)
#   2. list_posts_by_thread                 → Query PK=THREAD#id, SK begins_with POST#
#   3. get_post_by_id / update_post         → Need an inverse lookup → use
#       a "PostLookup" GSI keyed on POST#<post_id> when implementing, or
#       require the thread_id in the route (we already do for create; for
#       update we'd add a small GSI). Defer until the Dynamo impl lands.
#
# GSIs: NONE pre-provisioned. The route shape today (thread_id always in
#   path) makes most reads cheap without a secondary index.

resource "aws_dynamodb_table" "community_posts" {
  name         = "${var.table_prefix}community_posts"
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

  tags = merge(local.common_tags, { Domain = "community" })
}

# Votes (per-user upvotes/downvotes on threads + posts). Kept in its own
# table so its small, high-write item shape doesn't muddy hot-key diagnostics
# on the larger thread/post tables.
#
#   PK = TARGET#<target_type>#<target_id>     SK = USER#<user_id>
#
# Access patterns:
#   1. upsert_vote(user, target_type, target_id, value) → PutItem (overwrites)
#   2. remove_vote                                       → DeleteItem
#   3. get_user_vote                                     → GetItem (PK, SK)
#   4. Recompute counts for a target (after vote change)
#       → Query PK=TARGET#..., COUNT/aggregate in Lambda then UpdateItem
#         the denormalised count on the thread/post item.
#
# GSIs: NONE. No "what did user X vote on?" route exists.

resource "aws_dynamodb_table" "community_votes" {
  name         = "${var.table_prefix}community_votes"
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

  tags = merge(local.common_tags, { Domain = "community" })
}

# Addons (community-contributed courses, flashcard packs, stories, grammar).
# Listed by kind + language; filtered by author for "My Content".
#
#   PK = ADDON#<addon_id>            SK = META
#   GSI1PK = "KIND#<kind>"           GSI1SK = "<updated_at>"  (browse by kind)
#   GSI2PK = "AUTHOR#<author_id>"    GSI2SK = "<updated_at>"  (my content)
#
# Two GSIs because the two list paths are both first-class and neither
# subsumes the other. Status filter (draft / published) is applied
# client-side over the GSI page — status distribution is bimodal and the
# extra partition would burn WCU for a cheap in-memory filter.

resource "aws_dynamodb_table" "community_addons" {
  name         = "${var.table_prefix}community_addons"
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
    name            = "KindUpdated-Index"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "AuthorUpdated-Index"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "ALL"
  }

  tags = merge(local.common_tags, { Domain = "community" })
}

# Markdown KV (rich content blobs — addon READMEs, flashcard pack JSON, etc.)
# Pure key→content lookup; no list-by-prefix patterns today.
#
#   PK = MD#<key>      SK = META
#
# Access patterns:
#   1. store_markdown / get_markdown / delete_markdown → PutItem / GetItem / DeleteItem
#
# GSIs: NONE. Keys are namespaced path-like strings (addons/abc123/readme)
#   but there's no Scan-by-prefix route in the protocol. Add one only if a
#   future "list all markdown under addons/<id>/" route appears.

resource "aws_dynamodb_table" "community_markdown" {
  name         = "${var.table_prefix}community_markdown"
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

  tags = merge(local.common_tags, { Domain = "community" })
}

# ── Jobs (lingo-ops batch-job telemetry log) ──────────────────────────────────
#
# Append-only history of batch-job runs (nightly aggregation, TTS regen,
# deck-approval sweeps, …). The lingo-ops admin dashboard reads it; the
# batch scripts themselves write via POST /api/ops/v1/jobs/log.
#
# Key layout (mirrors app/db/dynamo/jobs.py):
#   PK = "JOB#<job_name>"       SK = "RUN#<started_at_iso>#<id>"
#   GSI1PK = "ALL"              GSI1SK = "<started_at_iso>#<id>"
#
# Access patterns + decision log:
#   1. log(job)            → PutItem
#   2. recent(job_name=X)  → Query PK=JOB#X, ScanIndexForward=False
#   3. recent() (all)      → Query AllRecent-Index, GSI1PK="ALL", desc
#   4. last_24h_counts()   → Query AllRecent-Index with GSI1SK >= 24h-ago
#   5. by_job_summary()    → Scan AllRecent-Index, group in Lambda
#   6. delete_older_than() → Query AllRecent-Index with GSI1SK < cutoff,
#                            BatchWriteItem(delete) by (PK, SK)
#
# Why single-partition GSI is fine:
#   ~10-100 runs/day max. Dynamo's per-partition hot-write threshold
#   kicks in around ~1000 writes/sec. When traffic grows we'd shard
#   GSI1PK = "ALL#<day>" — same read code (issue N queries).
#
# Why NO GSI on status:
#   4 status values, "recent failed" is the only realistic filter, and
#   over-fetching the most recent 500 from the GSI is cheaper than the
#   WCU amplification of a per-status sparse GSI at our volume.
#
# TTL: enabled on "ttl" (epoch seconds, set by the app to
# started_at + 90d). Auto-purges old rows so the DELETE /jobs/old admin
# endpoint becomes a no-op in steady state — it's still implemented for
# parity with SQLite and for on-demand window shrinking.
#
# Domain = "ops" — the only table this service owns.

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.table_prefix}jobs"
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

  global_secondary_index {
    name            = "AllRecent-Index"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, { Domain = "ops" })
}

# ── lingo-ops Lambda (admin-only ops/finance API) ─────────────────────────────
#
# Deploys via Lambda Function URL (NOT API Gateway) per cost discipline —
# Function URLs add zero per-request fees on top of Lambda invocation.
# CORS is set here at the function-URL level; auth is handled by the
# application via Auth0 JWT + ADMIN_USER_IDS allow-list.
#
# IAM least-privilege:
#   - Basic execution role (CloudWatch Logs only — managed policy).
#   - Inline policy granting Dynamo CRUD on lingo_jobs + its GSI ONLY.
#   - Cost Explorer read APIs (pinned to us-east-1, the only region CE
#     accepts).
#   - NO Stripe/AdSense secrets — those arrive as env vars set out-of-band
#     by the maintainer (see DEPLOY.md).
#
# Arch: ARM64 (Graviton2) — ~20% cheaper than x86 at identical perf for
# Python workloads. The build script (lingo-ops/scripts/build-zip.sh)
# already targets manylinux2014_aarch64.

variable "lingo_ops_zip_path" {
  description = "Path to the lingo-ops Lambda zip built by scripts/build-zip.sh. Defaults to the sibling repo's dist output; override with -var or .tfvars if the layout differs."
  type        = string
  default     = "../lingo-ops/dist/lingo-ops.zip"
}

# Trust policy: only Lambda can assume this role.
data "aws_iam_policy_document" "lingo_ops_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lingo_ops_lambda" {
  name               = "lingo-ops-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lingo_ops_lambda_assume.json
  tags               = merge(local.common_tags, { Domain = "ops" })
}

# CloudWatch Logs basic execution. The AWS-managed policy is fine here —
# it scopes to log-group create/put for this function only.
resource "aws_iam_role_policy_attachment" "lingo_ops_basic_exec" {
  role       = aws_iam_role.lingo_ops_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline extras: jobs table CRUD + Cost Explorer read.
data "aws_iam_policy_document" "lingo_ops_lambda_extras" {
  # Jobs table — CRUD on the table itself.
  statement {
    sid = "JobsTableCRUD"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.jobs.arn,
      "${aws_dynamodb_table.jobs.arn}/index/*",
    ]
  }

  # Cost Explorer — read-only metering APIs. CE is global but its API
  # endpoint lives in us-east-1 only; pinning the resource ARN here is
  # informational since CE doesn't support resource-level perms (all CE
  # actions are "*" by spec), but keeping the condition makes the intent
  # explicit in audits.
  statement {
    sid = "CostExplorerRead"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lingo_ops_lambda_extras" {
  name        = "lingo-ops-lambda-extras"
  description = "lingo_jobs CRUD + Cost Explorer read for the lingo-ops Lambda."
  policy      = data.aws_iam_policy_document.lingo_ops_lambda_extras.json
}

resource "aws_iam_role_policy_attachment" "lingo_ops_extras" {
  role       = aws_iam_role.lingo_ops_lambda.name
  policy_arn = aws_iam_policy.lingo_ops_lambda_extras.arn
}

# The Lambda itself.
resource "aws_lambda_function" "lingo_ops" {
  function_name = "lingo-ops"
  role          = aws_iam_role.lingo_ops_lambda.arn
  handler       = "app.handler.handler"
  runtime       = "python3.13"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30

  filename         = var.lingo_ops_zip_path
  source_code_hash = filebase64sha256(var.lingo_ops_zip_path)

  environment {
    # Placeholder values — the maintainer fills the secret-bearing keys
    # via the AWS console (see DEPLOY.md). The lifecycle block below
    # tells Terraform to leave env vars alone on subsequent applies so
    # the console-set values don't get clobbered.
    # NOTE: AWS_REGION is reserved by Lambda — it's auto-set to the
    # function's region and cannot be overridden via the environment
    # block (terraform plan will reject it). Pydantic Settings picks it
    # up from the runtime env automatically, so settings.AWS_REGION
    # resolves correctly without us defining it here.
    variables = {
      DB_BACKEND                        = "dynamodb"
      DYNAMODB_TABLE_PREFIX             = var.table_prefix
      AUTH0_DOMAIN                      = ""
      AUTH0_AUDIENCE                    = ""
      ADMIN_USER_IDS                    = "[]"
      OPS_JOB_TOKEN                     = "changeme"
      CORS_ORIGINS                      = "[\"https://openlingoapp.com\", \"https://www.openlingoapp.com\"]"
      STRIPE_API_KEY                    = ""
      STRIPE_WEBHOOK_SECRET             = ""
      GOOGLE_ADSENSE_ACCOUNT            = ""
      GOOGLE_OAUTH_CLIENT_ID            = ""
      GOOGLE_OAUTH_CLIENT_SECRET        = ""
      GOOGLE_OAUTH_REFRESH_TOKEN        = ""
      AWS_COST_READER_ACCESS_KEY_ID     = ""
      AWS_COST_READER_SECRET_ACCESS_KEY = ""
    }
  }

  lifecycle {
    # Once the maintainer sets real secrets via console, never overwrite
    # them on subsequent `terraform apply`. The variable block above is
    # only used on initial creation.
    #
    # source_code_hash + filename are ignored so the lingo-ops repo's own
    # deploy workflow owns code updates via aws lambda update-function-code.
    # Terraform manages infra (memory, timeout, env structure); CI manages
    # the code. Clean separation, no double-deploy.
    ignore_changes = [
      environment[0].variables,
      source_code_hash,
      filename,
    ]
  }

  tags = merge(local.common_tags, { Domain = "ops" })
}

# Function URL — public HTTPS endpoint, NO API Gateway.
resource "aws_lambda_function_url" "lingo_ops" {
  function_name      = aws_lambda_function.lingo_ops.function_name
  authorization_type = "NONE" # App handles auth via Auth0 JWT.

  cors {
    # Locked to the production lingo origin — update when the real
    # domain is in place. Adding multiple origins is fine; wildcards
    # would defeat the point of the CORS layer.
    allow_origins  = ["https://openlingoapp.com", "https://www.openlingoapp.com"]
    allow_methods  = ["GET", "POST", "PUT", "DELETE"]
    allow_headers  = ["authorization", "content-type", "x-dev-user"]
    expose_headers = ["content-type"]
    max_age        = 3600
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

output "social_table_name" {
  value = aws_dynamodb_table.social.name
}

output "social_leaderboard_table_name" {
  value = aws_dynamodb_table.social_leaderboard.name
}

output "deck_votes_table_name" {
  value = aws_dynamodb_table.deck_votes.name
}

output "jobs_table_name" {
  value = aws_dynamodb_table.jobs.name
}

output "lingo_ops_function_name" {
  value = aws_lambda_function.lingo_ops.function_name
}

# Paste this URL into lingo's prod .env.production as VITE_OPS_API_BASE_URL.
output "lingo_ops_url" {
  description = "Public HTTPS endpoint for the lingo-ops Lambda. Wire into lingo as VITE_OPS_API_BASE_URL."
  value       = aws_lambda_function_url.lingo_ops.function_url
}

# ── Deploy IAM user (CI / terraform apply from GitHub Actions) ────────────
# Why a dedicated user: CI needs long-lived programmatic credentials that
# can be rotated independently of the maintainer's personal access. The
# user gets AdministratorAccess because Terraform here creates IAM, Lambda,
# Dynamo, Secrets Manager — narrowing further would be a per-action
# allow-list that's a bigger maintenance burden than the side-project
# scale justifies.
#
# Tripwire: when this project grows past a small team OR when CI starts
# running anything beyond `terraform plan`/`apply`, migrate to GitHub
# OIDC + a short-lived AssumeRole instead of long-lived keys. See
# docs/dev/aws-environments.md (lingo monorepo) for the migration target.

resource "aws_iam_user" "deploy" {
  name = "lingo-deploy"
  tags = merge(local.common_tags, { Domain = "ops" })
}

resource "aws_iam_user_policy_attachment" "deploy_admin" {
  user       = aws_iam_user.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "deploy" {
  user = aws_iam_user.deploy.name
}

# Stash the credentials in Secrets Manager so the maintainer can retrieve
# them after apply without having to capture terraform output. Costs $0.40
# per secret per month — negligible.
resource "aws_secretsmanager_secret" "deploy_credentials" {
  name        = "lingo/deploy-iam-credentials"
  description = "Access keys for the lingo-deploy IAM user. Paste into GitHub org secrets."
  tags        = merge(local.common_tags, { Domain = "ops" })
}

resource "aws_secretsmanager_secret_version" "deploy_credentials" {
  secret_id = aws_secretsmanager_secret.deploy_credentials.id
  secret_string = jsonencode({
    aws_access_key_id     = aws_iam_access_key.deploy.id
    aws_secret_access_key = aws_iam_access_key.deploy.secret
  })
}

output "deploy_user_arn" {
  value = aws_iam_user.deploy.arn
}

# Retrieve the live credentials with:
#   aws secretsmanager get-secret-value \
#     --secret-id lingo/deploy-iam-credentials \
#     --query SecretString --output text | jq .
output "deploy_credentials_secret_arn" {
  value = aws_secretsmanager_secret.deploy_credentials.arn
}
