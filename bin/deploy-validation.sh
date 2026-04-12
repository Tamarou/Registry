#!/bin/bash
# ABOUTME: Run Playwright browser tests against the live production site.
# ABOUTME: Use after deployment to verify rendering, styling, and functionality.

set -e

URL="${DEPLOY_VALIDATION_URL:-https://tinyartempire.com}"

echo "=== Deploy Validation (Playwright) ==="
echo "Target: $URL"
echo ""

DEPLOY_VALIDATION_URL="$URL" npx playwright test \
  --project=deploy-validation \
  --reporter=list \
  "$@"
