#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <unraid-server>"
  exit 1
fi

UNRAID_SERVER="$1"
SRC_DIR="$(dirname "$0")"
DEST_DIR="/usr/local/unraid_view"
REMOTE="root@${UNRAID_SERVER}"

# Create parent directory on the remote server if it doesn't exist
ssh "$REMOTE" "mkdir -p '$DEST_DIR'"

# Rsync the Elixir source code to the remote server, excluding build, deps, and other unnecessary files
rsync -avz --delete \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='*.beam' \
  --exclude='*.ez' \
  --exclude='*.log' \
  --exclude='.git' \
  --exclude='*.swp' \
  --exclude='*.tmp' \
  --exclude='*.DS_Store' \
  --exclude='node_modules' \
  --exclude='priv/static/assets' \
  "$SRC_DIR/" "$REMOTE:$DEST_DIR/"

echo "Source sync to $UNRAID_SERVER:$DEST_DIR complete." 