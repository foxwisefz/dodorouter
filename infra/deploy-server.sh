#!/bin/bash
set -euo pipefail

VERSION=$1
RELEASE_DIR="$HOME/dodorouter/current"
TARBALL="/tmp/dodo_router-${VERSION}.tar.gz"

if [ ! -f "$TARBALL" ]; then
  echo "ERROR: Release tarball not found: $TARBALL"
  exit 1
fi

echo "=== Deploying dodo-router v${VERSION} ==="

# Ensure release directory exists
mkdir -p "$RELEASE_DIR"

# Check if service is currently running
if systemctl --user is-active --quiet dodo-router; then
  echo "Service is running. Performing hot upgrade via Castle..."
  
  # Copy tarball to releases directory
  mkdir -p "$RELEASE_DIR/releases"
  cp "$TARBALL" "$RELEASE_DIR/releases/dodo_router-${VERSION}.tar.gz"
  
  # Use Castle commands for upgrade
  cd "$RELEASE_DIR"
  
  echo "Unpacking release ${VERSION}..."
  ./bin/dodo_router unpack "$VERSION"
  
  echo "Installing release ${VERSION}..."
  ./bin/dodo_router install "$VERSION"
  
  echo "Committing release ${VERSION}..."
  ./bin/dodo_router commit "$VERSION"
  
  echo "Hot upgrade to v${VERSION} completed successfully!"
else
  echo "Service not running. Performing full install..."
  
  # Extract full release
  cd "$RELEASE_DIR"
  tar xzf "$TARBALL"
  
  # Start service
  systemctl --user enable dodo-router
  systemctl --user start dodo-router
  
  echo "Full install completed!"
fi

# Clean up tarball
rm -f "$TARBALL"

echo "=== Deploy complete ==="
