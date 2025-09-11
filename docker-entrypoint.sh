#!/bin/bash

# Docker entrypoint script for Registry services
# Determines which service to start based on SERVICE_TYPE environment variable

set -e

# Function to deploy database schema (only for web service)
deploy_schema() {
    echo "Deploying database schema..."
    if [ -n "$DB_URL" ]; then
        echo "Using database URL: ${DB_URL%:*}:****"
        if carton exec sqitch deploy --target "$DB_URL"; then
            echo "Database schema deployed successfully"
        else
            echo "Warning: Database schema deployment failed"
        fi
    else
        echo "Error: DB_URL environment variable not set"
        return 1
    fi
    
    echo "Importing workflows and templates..."
    if carton exec ./registry workflow import registry; then
        echo "Workflows imported successfully"
    else
        echo "Warning: Workflow import failed"
    fi
    
    if carton exec ./registry template import registry; then
        echo "Templates imported successfully"
    else
        echo "Warning: Template import failed"
    fi
}

case "${SERVICE_TYPE:-web}" in
    "web")
        echo "Starting web service..."
        deploy_schema
        exec carton exec hypnotoad -f ./registry
        ;;
    "worker")
        echo "Starting worker service..."
        exec carton exec ./registry minion worker
        ;;
    "scheduler")
        echo "Starting scheduler tasks..."
        carton exec ./registry job attendance_check
        carton exec ./registry job waitlist_expiration
        ;;
    *)
        echo "Unknown SERVICE_TYPE: ${SERVICE_TYPE}"
        echo "Valid options: web, worker, scheduler"
        exit 1
        ;;
esac