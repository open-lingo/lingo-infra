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

# `Project` and `Environment` apply to every resource this provider
# creates and are inherited via `default_tags`. Per-resource `tags =
# { Domain = "<domain>" }` blocks merge on top so AWS Cost Explorer can
# break spend down by domain — powers /api/ops/v1/finance/costs/by-domain
# in lingo-ops.
#
# `Domain` is intentionally NOT defaulted: keeping it per-resource means
# a forgotten override surfaces in code review rather than silently
# bucketing into a fallback domain and skewing the cost rollup.
#
# Cost allocation tags become queryable only after a one-time activation
# in the AWS Billing console (Cost allocation tags → Activate `Project`,
# `Environment`, `Domain`), with ~24h propagation. See docs/cost-tags.md.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "open-lingo"
      Environment = var.environment
    }
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

  tags = { Domain = "users" }
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
  tags = { Domain = "users" }
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

  tags = { Domain = "srs" }
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

  tags = { Domain = "decks" }
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

  tags = { Domain = "progress" }
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

  tags = { Domain = "social" }
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

  tags = { Domain = "social" }
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

  tags = { Domain = "decks" }
}

# ── Tags (admin-curated deck tag dictionary + deck ↔ tag join) ──────────────
#
# Backs lingo-core /api/core/v1/tags (public list) and the admin tag
# routes under /api/core/v1/admin/tags. Mirrors the SQLite reference impl
# in app/db/sqlite/tag.py (two tables: tags + deck_tags) flattened into a
# single Dynamo table per the standard single-table pattern.
#
# Status: NOT YET IMPLEMENTED in app/db/dynamo/tag.py — the stub raises
# NotImplementedError on every method. SQLite is the working backend
# today. This table is provisioned ahead of the cut-over so the
# implementer doesn't get blocked on infra. Tagged Domain = "decks"
# because tags live under the decks UX surface (community browse facets,
# deck create picker).
#
# Key layout:
#   PK = SLUG#<slug>           SK = META                # canonical tag row
#   PK = DECK#<deck_id>        SK = TAG#<slug>          # deck → tag mirror
#   GSI1PK = TAG#<slug>        GSI1SK = DECK#<deck_id>  # reverse lookup
#
# Access patterns + decision log:
#   1. list_tags()                  → Scan PK begins_with SLUG#, SK=META.
#      Canonical tag dictionary is bounded (<200 rows in practice), so a
#      Scan is cheaper than maintaining a GSI just to list. Add a GSI
#      with a fixed partition (PK="ALL_TAGS") only if the dictionary ever
#      grows past ~5k rows.
#   2. get_tag(slug)                → GetItem (PK=SLUG#x, SK=META)
#   3. create / update / delete_tag → PutItem / UpdateItem / DeleteItem
#      under PK=SLUG#x. Cascade for delete: Query GSI1PK=TAG#x for all
#      DECK#d rows, BatchWriteItem(delete).
#   4. list_tags_for_deck(deck)     → Query PK=DECK#d, SK begins_with TAG#
#   5. list_decks_for_tag(slug)     → Query GSI1PK=TAG#x  (the reverse GSI)
#   6. set_deck_tags(deck, slugs)   → Query existing DECK#d/TAG#* rows,
#      diff, BatchWriteItem(put new + delete missing). Replace semantics
#      mirror the SQLite impl.
#
# GSIs: ONE.
#   TagDeck-Index (GSI1PK / GSI1SK) — reverse lookup "which decks carry
#   tag X". Used by list_decks_for_tag and for the cascade on tag delete.
#   Cheap to maintain (deck_tags writes are admin/owner edits, not hot).
#
# TTL: NONE. Tags + mappings are persistent.

resource "aws_dynamodb_table" "tags" {
  name         = "${var.table_prefix}tags"
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
    name            = "TagDeck-Index"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  tags = { Domain = "decks" }
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

  tags = { Domain = "community" }
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

  tags = { Domain = "community" }
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

  tags = { Domain = "community" }
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

  tags = { Domain = "community" }
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

  tags = { Domain = "community" }
}

# ── Quests (per-user quest progress) ──────────────────────────────────────────
#
# Drives the quests/streak system surfaced on the social/learn pages. Every row
# is owned by exactly one user, and the only query is "list my quests" — so a
# single Query on PK is sufficient and no GSI is warranted yet.
#
# Key layout:
#   PK = USER#<user_id>     SK = QUEST#<quest_id>

resource "aws_dynamodb_table" "quests" {
  name         = "${var.table_prefix}quests"
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

  tags = { Domain = "quests" }
}

# ── Admin audit log (operator action history) ─────────────────────────────────
#
# Append-only log of admin actions taken via lingo-ops. Lexicographic SK
# (<iso_at>#<id>) means a single descending Query gives chronological order.
#
# Key layout:
#   PK = "AUDIT"            SK = "<iso_at>#<id>"
#   attrs: actor_id (S), at (S), target_kind (S), …
#
# GSIs:
#   ActorIndex      hash=actor_id     range=at   — filter by actor
#   TargetKindIndex hash=target_kind  range=at   — filter by target type

resource "aws_dynamodb_table" "admin_audit" {
  name         = "${var.table_prefix}admin_audit"
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
    name = "actor_id"
    type = "S"
  }
  attribute {
    name = "at"
    type = "S"
  }
  attribute {
    name = "target_kind"
    type = "S"
  }

  global_secondary_index {
    name            = "ActorIndex"
    hash_key        = "actor_id"
    range_key       = "at"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "TargetKindIndex"
    hash_key        = "target_kind"
    range_key       = "at"
    projection_type = "ALL"
  }

  tags = { Domain = "ops" }
}

# ── Platform settings (admin-tunable key/value config) ────────────────────────
#
# Single-row-per-key table: PK is the setting name (e.g. "xp_economy"), SK is
# a constant "META" so the table is essentially a typed key/value store. Reads
# are GetItem; writes are PutItem. No GSIs.

resource "aws_dynamodb_table" "platform_settings" {
  name         = "${var.table_prefix}platform_settings"
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

  tags = { Domain = "ops" }
}

# ── Stories (admin-authored narrative content) ────────────────────────────────
#
# One row per story (PK=STORY#<id>, SK="META").
#
# GSIs:
#   LanguageStatusIndex hash=language_id range=status_updated_at
#     status_updated_at = "<status>#<updated_at>" so the admin filter
#     "?status=draft|published&language_id=ja" is a single Query with
#     begins_with(status_updated_at, "draft#") (or "published#").
#   AuthorIndex hash=author_id range=created_at — "stories I authored, newest first"

resource "aws_dynamodb_table" "stories" {
  name         = "${var.table_prefix}stories"
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
    name = "language_id"
    type = "S"
  }
  attribute {
    name = "status_updated_at"
    type = "S"
  }
  attribute {
    name = "author_id"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "LanguageStatusIndex"
    hash_key        = "language_id"
    range_key       = "status_updated_at"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "AuthorIndex"
    hash_key        = "author_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  tags = { Domain = "content" }
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

  tags = { Domain = "ops" }
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
  tags               = { Domain = "ops" }
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
  tags        = { Domain = "ops" }
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
      DB_BACKEND                 = "dynamodb"
      DYNAMODB_TABLE_PREFIX      = var.table_prefix
      AUTH0_DOMAIN               = ""
      AUTH0_AUDIENCE             = ""
      ADMIN_USER_IDS             = "[]"
      OPS_JOB_TOKEN              = "changeme"
      CORS_ORIGINS               = "[\"https://openlingoapp.com\", \"https://www.openlingoapp.com\"]"
      STRIPE_API_KEY             = ""
      STRIPE_WEBHOOK_SECRET      = ""
      GOOGLE_ADSENSE_ACCOUNT     = ""
      GOOGLE_OAUTH_CLIENT_ID     = ""
      GOOGLE_OAUTH_CLIENT_SECRET = ""
      GOOGLE_OAUTH_REFRESH_TOKEN = ""
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

  tags = { Domain = "ops" }
}

# Function URL — public HTTPS endpoint, NO API Gateway.
resource "aws_lambda_function_url" "lingo_ops" {
  function_name      = aws_lambda_function.lingo_ops.function_name
  authorization_type = "NONE" # App handles auth via Auth0 JWT.

  # CORS handled by the FastAPI CORSMiddleware in `app/main.py` — keeping
  # Function URL CORS configured ALSO causes duplicate
  # `Access-Control-Allow-Origin` and `Vary: Origin` response headers
  # (browsers reject the response per CORS spec). lingo-core's Function URL
  # has no CORS block for the same reason. Single source of truth = the app.
}

# NOTE (Oct-2025 AWS change): NONE-auth function URLs need a SECOND resource-policy
# statement — lambda:InvokeFunction with condition lambda:InvokedViaFunctionUrl=true —
# in addition to the lambda:InvokeFunctionUrl one. Provider ~> 5.0 can't express that
# condition (added in provider 6.x), so it's applied via CLI (statement id
# "FunctionURLAllowPublicInvoke", currently present on lingo-ops and lingo-core).
# See lingo_core_function.tf for the exact command. Without it the URL returns 403.
resource "aws_lambda_permission" "lingo_ops_public_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.lingo_ops.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# ── lingo-events SQS queue (producers: lingo-core, lingo-ops; consumer: lingo-async) ─
#
# Standard (non-FIFO) queue. Order isn't required — handlers are commutative
# (an xp_awarded event for user U applies the same delta regardless of whether
# it arrives before or after the lesson_completed it came from).
#
# Visibility timeout = 60s: long enough for one cold-start (≤3s) plus N
# Dynamo round-trips per message at worst-case batch-of-10 throughput. Lambda
# itself caps at 30s per the function config; the extra 30s margin guards
# against the rare slow-start case.
#
# Retention = 4 days: replays we'd want past that horizon are bug archaeology,
# not normal operation — the producer record + CloudWatch trail get us there.
#
# Redrive: after 3 receives, the message moves to lingo-events-dlq for
# inspection. maxReceiveCount = 3 follows AWS's standard recommendation
# (one retry handles transient throttles; three protects against intermittent
# downstream flakiness without burning excessive Dynamo write capacity).

resource "aws_sqs_queue" "lingo_events_dlq" {
  name                      = "lingo-events-dlq"
  message_retention_seconds = 1209600 # 14 days — DLQ horizon

  tags = { Domain = "async" }
}

resource "aws_sqs_queue" "lingo_events" {
  name                       = "lingo-events"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.lingo_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Domain = "async" }
}

# ── lingo-async Lambda (SQS-driven worker — quest eval, leaderboard updates) ──
#
# NO Function URL, NO API Gateway. Triggered by SQS event source mapping
# (see aws_lambda_event_source_mapping.lingo_async below).
#
# IAM least-privilege:
#   - Basic execution role (CloudWatch Logs only — managed policy).
#   - Inline policy granting:
#       * SQS receive/delete/getQueueAttributes on lingo-events ONLY (DLQ
#         writes go through the redrive policy on the queue, not via the
#         consumer's IAM).
#       * Dynamo UpdateItem on lingo_social_leaderboard (real today).
#       * Dynamo GetItem on lingo_users (read learning language + opt-in
#         flag before writing to the leaderboard).
#       * Dynamo Get/Update/Query on lingo_quests (future — the table
#         doesn't exist yet, so the resource ARN below is intentionally
#         a wildcard for the prefix; when the table lands, swap this for
#         the concrete table ARN).
#
# Arch: ARM64 (Graviton2) — matches lingo-core / lingo-ops.

variable "lingo_async_zip_path" {
  description = "Path to the lingo-async Lambda zip built by scripts/build-zip.sh. Defaults to the sibling repo's dist output; override with -var or .tfvars if the layout differs."
  type        = string
  default     = "../lingo-async/dist/lingo-async.zip"
}

# Shared service-to-service token for lingo-async -> lingo-core callbacks.
# Sensitive, no default: supply via `TF_VAR_internal_service_token=...` at
# apply time (or an uncommitted .tfvars). Must be byte-identical to the
# INTERNAL_SERVICE_TOKEN set on the lingo-core Lambda (managed there via the
# console, since core's env is ignore_changes-protected). Mismatch -> 401;
# empty on core -> 500.
variable "internal_service_token" {
  description = "Shared bearer token for lingo-async -> lingo-core internal callbacks. Must match lingo-core's INTERNAL_SERVICE_TOKEN."
  type        = string
  sensitive   = true
}

# Trust policy: only Lambda can assume this role.
data "aws_iam_policy_document" "lingo_async_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lingo_async_lambda" {
  name               = "lingo-async-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lingo_async_lambda_assume.json
  tags               = { Domain = "async" }
}

resource "aws_iam_role_policy_attachment" "lingo_async_basic_exec" {
  role       = aws_iam_role.lingo_async_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline extras: SQS consumer perms + Dynamo Get/Update on user / leaderboard /
# quest tables. Quests table doesn't exist yet — the wildcard ARN spans the
# whole prefix so adding the table later requires no IAM change.
data "aws_iam_policy_document" "lingo_async_lambda_extras" {
  statement {
    sid = "SqsConsumer"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.lingo_events.arn]
  }

  statement {
    sid = "LeaderboardUpdate"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.social_leaderboard.arn]
  }

  statement {
    sid = "UserRead"
    actions = [
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.users.arn]
  }

  # Future quests table — not provisioned yet. Wildcard so when
  # lingo_quests lands, no IAM change is required.
  statement {
    sid = "QuestsRW"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      "arn:aws:dynamodb:*:*:table/${var.table_prefix}quests",
      "arn:aws:dynamodb:*:*:table/${var.table_prefix}quests/index/*",
    ]
  }
}

resource "aws_iam_policy" "lingo_async_lambda_extras" {
  name        = "lingo-async-lambda-extras"
  description = "SQS receive/delete + Dynamo R/W for the lingo-async Lambda."
  policy      = data.aws_iam_policy_document.lingo_async_lambda_extras.json
  tags        = { Domain = "async" }
}

resource "aws_iam_role_policy_attachment" "lingo_async_extras" {
  role       = aws_iam_role.lingo_async_lambda.name
  policy_arn = aws_iam_policy.lingo_async_lambda_extras.arn
}

resource "aws_lambda_function" "lingo_async" {
  function_name = "lingo-async"
  role          = aws_iam_role.lingo_async_lambda.arn
  handler       = "app.handler.lambda_handler"
  runtime       = "python3.13"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30

  filename         = var.lingo_async_zip_path
  source_code_hash = filebase64sha256(var.lingo_async_zip_path)

  environment {
    variables = {
      DYNAMODB_TABLE_PREFIX = var.table_prefix
      LOG_LEVEL             = "INFO"

      # Service-to-service callbacks into lingo-core (quest progress, XP,
      # leaderboard). Without these the worker defaults to localhost:8000
      # with an empty token — every callback fails. LINGO_CORE_URL points
      # at the core Lambda's Function URL (the client appends /api/core/v1
      # and rstrips the trailing slash). INTERNAL_SERVICE_TOKEN must match
      # the value set on lingo-core (console-managed there). Supply the
      # token via TF_VAR_internal_service_token at apply time — never hard-
      # code the secret in this file.
      LINGO_CORE_URL         = aws_lambda_function_url.lingo_core.function_url
      INTERNAL_SERVICE_TOKEN = var.internal_service_token
    }
  }

  lifecycle {
    # The lingo-async repo's deploy workflow owns code updates via
    # aws lambda update-function-code (same pattern as lingo-ops).
    # Env vars (incl. the secret above) are Terraform-managed: this
    # resource has NO ignore_changes on environment, so a console edit
    # would be reverted on the next apply. Change env here, not the console.
    ignore_changes = [
      source_code_hash,
      filename,
    ]
  }

  tags = { Domain = "async" }
}

# Connect the queue to the function. Batch size 10 is the SQS standard
# default — each invocation gets up to 10 messages. The partial-batch-
# failure response type means we return a list of message ids to retry
# (vs. fail-the-whole-batch). The lambda_handler code returns
# {batchItemFailures: [...]} — see app/handler.py.
resource "aws_lambda_event_source_mapping" "lingo_async" {
  event_source_arn = aws_sqs_queue.lingo_events.arn
  function_name    = aws_lambda_function.lingo_async.arn
  batch_size       = 10

  function_response_types = ["ReportBatchItemFailures"]
}

# ── Producer IAM: SendMessage on lingo-events ─────────────────────────────────
#
# lingo-ops gets the extra perm via its existing extras policy below. lingo-
# core is NOT Terraform-managed in this repo as of 2026-05-27 — the
# maintainer adds sqs:SendMessage on the lingo-events queue to whatever
# IAM principal lingo-core runs under, by hand. See DEPLOY.md in
# lingo-async for the exact policy JSON.

# Extra perm for the lingo-ops Lambda — append send-message rights to a
# dedicated policy so we don't have to edit the existing extras policy
# JSON (cleaner diff).
data "aws_iam_policy_document" "lingo_ops_events_publish" {
  statement {
    sid       = "PublishLingoEvents"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lingo_events.arn]
  }
}

resource "aws_iam_policy" "lingo_ops_events_publish" {
  name        = "lingo-ops-events-publish"
  description = "Allow lingo-ops Lambda to publish to the lingo-events SQS queue."
  policy      = data.aws_iam_policy_document.lingo_ops_events_publish.json
  tags        = { Domain = "ops" }
}

resource "aws_iam_role_policy_attachment" "lingo_ops_events_publish" {
  role       = aws_iam_role.lingo_ops_lambda.name
  policy_arn = aws_iam_policy.lingo_ops_events_publish.arn
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

# Producers need this as EVENTS_QUEUE_URL env var (lingo-core, lingo-ops).
output "lingo_events_queue_url" {
  description = "SQS queue URL for the lingo-events fan-out queue. Wire into producers as EVENTS_QUEUE_URL."
  value       = aws_sqs_queue.lingo_events.url
}

output "lingo_events_queue_arn" {
  description = "ARN of the lingo-events queue — handy for granting sqs:SendMessage to producers managed outside this Terraform (e.g. lingo-core)."
  value       = aws_sqs_queue.lingo_events.arn
}

output "lingo_events_dlq_url" {
  description = "Dead-letter queue URL — peek here when messages exceed maxReceiveCount."
  value       = aws_sqs_queue.lingo_events_dlq.url
}

output "lingo_async_function_name" {
  value = aws_lambda_function.lingo_async.function_name
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
  tags = { Domain = "ops" }
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
  tags        = { Domain = "ops" }
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
