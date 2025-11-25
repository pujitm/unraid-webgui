#!/bin/bash

# Script to run the production release
# Make sure you've built the release first with ./build_release.sh

RELEASE_PATH="_build/prod/rel/unraid_view/bin/unraid_view"

if [ ! -f "$RELEASE_PATH" ]; then
    echo "❌ Release not found at $RELEASE_PATH"
    echo "Please build the release first with: ./build_release.sh"
    exit 1
fi

echo "🚀 Starting Unraid View Release..."
echo ""
echo "App will be available at:"
echo "  - http://zima.local:4000"
echo "  - http://hanzo.local:4000"
echo "  - http://localhost:4000"
echo ""
echo "To stop the release, use Ctrl+C or run:"
echo "  $RELEASE_PATH stop"
echo ""

# Start the release
$RELEASE_PATH start 