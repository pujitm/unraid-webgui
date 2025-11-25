#!/bin/bash

# Development script for Unraid View Elixir Phoenix app
echo "🛠️ Starting Unraid View Development Server..."

# Install dependencies
echo "📦 Installing dependencies..."
mix deps.get

# Start the Phoenix server in development mode
echo "🌐 Starting development server..."
echo "App will be available at:"
echo "  - http://localhost:4000"
echo ""
echo "Press Ctrl+C to stop the server"

# Run the Phoenix server in development mode
mix phx.server 