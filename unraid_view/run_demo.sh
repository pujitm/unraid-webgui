#!/bin/bash

# Demo script for Unraid View Elixir Phoenix app
# This script prepares and runs the app for live demonstration

echo "🚀 Starting Unraid View Demo Setup..."

# Set production environment
export MIX_ENV=prod

# Install dependencies
echo "📦 Installing dependencies..."
mix deps.get --only prod

# Compile the application
echo "🔨 Compiling application..."
mix compile

# Deploy assets (CSS, JS, etc.)
echo "🎨 Deploying assets..."
mix assets.deploy

# Start the server
echo "🌐 Starting server..."
echo "App will be available at:"
echo "  - http://zima.local:4000"
echo "  - http://hanzo.local:4000"
echo "  - http://localhost:4000"
echo ""
echo "Press Ctrl+C to stop the server"

# Run the Phoenix server
PHX_SERVER=true mix phx.server 