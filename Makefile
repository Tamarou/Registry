.PHONY: test dev-server clean

test:
	carton exec prove -lr t/

dev-server:
	carton exec morbo ./app.pl

clean-db:
	dropdb registry; createdb registry; carton exec sqitch deploy


help:
	@echo "Available targets:"
	@echo "  test        - Run all tests using prove"
	@echo "  dev-server  - Start development server with morbo"
	@echo "  clean-db    - Drop and recreate the test database"
	@echo "  help        - Show this help message"

# Default target
all: help