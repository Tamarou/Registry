#!/bin/bash

# Docker entrypoint script for Registry services
# Determines which service to start based on SERVICE_TYPE environment variable

set -e

# Function to deploy database schema (only for web service)
deploy_schema() {
    echo "Deploying database schema..."
    if [ -n "$SQITCH_TARGET" ]; then
        echo "Using sqitch target: ${SQITCH_TARGET%:*}:****"
        if sqitch deploy; then
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
        exec ./registry daemon -l "http://*:${PORT:-10000}"
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