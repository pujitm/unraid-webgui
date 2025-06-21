#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <unraid-server>"
  exit 1
fi

UNRAID_SERVER="$1"
SRC_DIR="$(dirname "$0")/_build/prod/rel/unraid_view"
DEST_DIR="/usr/local/unraid_view/build"
REMOTE="root@${UNRAID_SERVER}"

# Create parent directories on the remote server if they don't exist
ssh "$REMOTE" "mkdir -p '$DEST_DIR'"

# Rsync the build to the remote server
rsync -avz --delete "$SRC_DIR/" "$REMOTE:$DEST_DIR/"

echo "Deployment to $UNRAID_SERVER:$DEST_DIR complete." 