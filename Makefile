.PHONY: test dev-server clean

test:
	carton exec prove -lr t/

dev-server:
	carton exec morbo ./registry

clean-db:
	dropdb registry
	createdb registry
	carton exec sqitch deploy
	carton exec ./registry template import registry


help:
	@echo "Available targets:"
	@echo "  test        - Run all tests using prove"
	@echo "  dev-server  - Start development server with morbo"
	@echo "  clean-db    - Drop and recreate the test database"
	@echo "  help        - Show this help message"

# Default target
all: help
