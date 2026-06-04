#!/usr/bin/env bash
# ABOUTME: Boots one morbo Registry server for Playwright against the shared DB.
# ABOUTME: Reads the DB URL written by global-setup.js.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DB_URL="$(cat t/playwright/.shared-db-url)"
export EMAIL_SENDER_TRANSPORT=Test
exec carton exec morbo ./registry -l http://127.0.0.1:3001
