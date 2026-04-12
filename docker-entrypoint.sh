#!/bin/bash

# Docker entrypoint script for Registry services
# Determines which service to start based on SERVICE_TYPE environment variable

set -e

# Function to deploy database schema (only for web service)
deploy_schema() {
    echo "Deploying database schema..."
    # Use SQITCH_TARGET if set, otherwise derive from DB_URL.
    # Sqitch requires db:pg:// URIs, not postgresql:// — convert if needed.
    local target="${SQITCH_TARGET:-$DB_URL}"
    target="${target/#postgresql:/db:pg:}"
    if [ -n "$target" ]; then
        echo "Using sqitch target: ${target%%@*}@****"
        if sqitch deploy "$target"; then
            echo "Database schema deployed successfully"
        else
            echo "Warning: Database schema deployment failed"
        fi
    else
        echo "Error: SQITCH_TARGET environment variable not set"
        return 1
    fi
    
    echo "Importing workflows and templates..."
    if ./registry workflow import registry; then
        echo "Workflows imported successfully"
    else
        echo "Warning: Workflow import failed"
    fi
    
    if ./registry template import registry; then
        echo "Templates imported successfully"
    else
        echo "Warning: Template import failed"
    fi
}

case "${SERVICE_TYPE:-web}" in
    "web")
        echo "Starting web service..."
        deploy_schema

        # Start the server in the background
        ./registry daemon -l "http://*:${PORT:-10000}" &
        SERVER_PID=$!

        # Wait for the server to be ready
        echo "Waiting for server to be ready..."
        for i in $(seq 1 30); do
            if curl -sf "http://localhost:${PORT:-10000}/health" > /dev/null 2>&1; then
                echo "Server is ready"
                break
            fi
            sleep 1
        done

        # Run post-deploy smoke test against the live URL
        # Failure kills the server so Render rolls back the deploy
        if [ -f bin/post-deploy-smoke-test.sh ] && [ -n "$BASE_URL" ]; then
            echo "Running post-deploy smoke test..."
            if ! bash bin/post-deploy-smoke-test.sh; then
                echo "FATAL: Smoke test failed -- killing server to trigger rollback"
                kill $SERVER_PID
                exit 1
            fi
        fi

        # Wait for the server process
        wait $SERVER_PID
        ;;
    "worker")
        echo "Starting worker service..."
        exec ./registry minion worker
        ;;
    "scheduler")
        echo "Starting scheduler tasks..."
        ./registry job attendance_check
        ./registry job waitlist_expiration
        ;;
    *)
        echo "Unknown SERVICE_TYPE: ${SERVICE_TYPE}"
        echo "Valid options: web, worker, scheduler"
        exit 1
        ;;
esac