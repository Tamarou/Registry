#!/bin/bash

# Deploy only the database schema via sqitch
# This is a one-time script to get the basic tables in place

echo "Deploying database schema via sqitch..."
carton exec sqitch deploy

echo "Schema deployment complete!"
echo "You can now run the workflow and template imports."