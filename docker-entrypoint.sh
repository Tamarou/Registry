#!/bin/bash

# Docker entrypoint script for Registry services
# Determines which service to start based on SERVICE_TYPE environment variable

set -e

case "${SERVICE_TYPE:-web}" in
    "web")
        echo "Starting web service..."
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