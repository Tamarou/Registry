.PHONY: test test-playwright test-all dev-server clean test-schema

test-schema:
	carton exec perl -It/lib -MTest::Registry::DB -e 'Test::Registry::DB::generate_dump()'

test: sql/test-schema.sql
	carton exec prove -lr t/

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
