.PHONY: test test-playwright test-all dev-server clean test-schema

test-schema:
	carton exec perl -It/lib -MTest::Registry::DB -e 'Test::Registry::DB::generate_dump()'

# Directories, not a bare `t/`; the list lives here so every document can keep
# saying `make test`.  A bare sweep pulls in the live-Stripe suite -- gated on a
# single STRIPE_SECRET_KEY prefix check that never looks at
# STRIPE_PUBLISHABLE_KEY, live in a developer shell -- and a Playwright fixture
# script that wants a running server.  Every other directory under t/ holding a
# .t file is named below; add new ones here.  The placeholder key is CI's, so
# the run does not depend on what the shell exports.  CI keeps its bare sweep on
# purpose (.github/workflows/ci.yml): that placeholder holds the gate shut, and
# the sweep is what proves the excluded files still compile.
test: sql/test-schema.sql
	STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/auth \
	  t/controller t/css t/dao t/database t/e2e t/frontend t/integration t/job \
	  t/priceops t/robustness t/security t/seed t/service t/unit t/user-journeys \
	  t/workflow -j8

sql/test-schema.sql: sql/deploy/*.sql sql/sqitch.plan
	@echo "Schema changed -- regenerating test dump..."
	@$(MAKE) test-schema

test-playwright:
	@if command -v npm >/dev/null 2>&1 && [ -f package.json ] && npm list @playwright/test >/dev/null 2>&1; then \
		echo "Running Playwright tests..."; \
		npm run test:playwright; \
	else \
		echo "Playwright not installed - skipping visual tests"; \
		echo "To install: npm install && npx playwright install"; \
	fi

test-all: test
	@$(MAKE) test-playwright

dev-server:
	carton exec morbo ./registry

reset:
	dropdb registry
	createdb registry
	carton exec sqitch deploy
	carton exec ./registry workflow import registry
	carton exec ./registry template import registry

help:
	@echo "Available targets:"
	@echo "  test             - Run all Perl tests using prove"
	@echo "  test-playwright  - Run Playwright visual/integration tests"
	@echo "  test-all         - Run all tests (Perl + Playwright)"
	@echo "  dev-server       - Start development server with morbo"
	@echo "  test-schema      - Regenerate sql/test-schema.sql from migrations"
	@echo "  reset            - Drop and recreate the database"
	@echo "  help             - Show this help message"

# Default target
all: help
