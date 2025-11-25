#!/bin/bash

# Production release build script for Unraid View Elixir Phoenix app
# This script creates a standalone release that can be deployed without Mix/Elixir

echo "🏗️ Building Unraid View Production Release..."

# Set production environment
export MIX_ENV=prod

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf _build/prod
rm -rf priv/static/assets

# Install dependencies
echo "📦 Installing production dependencies..."
mix deps.get --only prod

# Compile the application
echo "🔨 Compiling application..."
mix compile

# Deploy assets (CSS, JS, etc.)
echo "🎨 Deploying assets..."
mix assets.deploy

# Create the release
echo "📦 Creating release..."
mix release

# Get the release version
APP_VERSION=$(grep 'version:' mix.exs | sed 's/.*version: "\(.*\)".*/\1/')

echo ""
echo "✅ Release build completed successfully!"
echo ""
echo "📍 Release location: _build/prod/rel/unraid_view/"
echo "📦 Release version: $APP_VERSION"
echo ""
echo "🚀 To run the release:"
echo "  _build/prod/rel/unraid_view/bin/unraid_view start"
echo ""
echo "🔧 To run in daemon mode:"
echo "  _build/prod/rel/unraid_view/bin/unraid_view daemon"
echo ""
echo "🛑 To stop the release:"
echo "  _build/prod/rel/unraid_view/bin/unraid_view stop"
echo ""
echo "💡 The release is completely self-contained and can be"
echo "   copied to other systems without needing Elixir/Mix installed." 