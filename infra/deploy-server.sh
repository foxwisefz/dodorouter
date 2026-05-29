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
  echo "Service is running. Performing hot upgrade..."
  
  # Copy tarball to releases directory
  mkdir -p "$RELEASE_DIR/releases"
  cp "$TARBALL" "$RELEASE_DIR/releases/dodo_router-${VERSION}.tar.gz"
  
  cd "$RELEASE_DIR"
  
  # Ensure SASL is running (needed for release_handler)
  if ! ./bin/dodo_router rpc ":erlang.whereis(:release_handler)" | grep -q "pid"; then
    echo "Starting SASL..."
    ./bin/dodo_router rpc ":application.start(:sasl)"
    sleep 1
  fi
  
  # Use our custom upgrade module
  echo "Upgrading to v${VERSION}..."
  ./bin/upgrade "$VERSION"
  
  echo "Hot upgrade to v${VERSION} completed successfully!"
else
  echo "Service not running. Performing full install..."
  
  # Clear old release if any
  rm -rf "$RELEASE_DIR"/*
  
  # Extract full release
  cd "$RELEASE_DIR"
  tar xzf "$TARBALL"
  
  # Start service
  systemctl --user enable dodo-router
  systemctl --user start dodo-router
  
  echo "Full install completed!"
fi

# Verify version
sleep 2
ACTUAL_VERSION=$(./bin/dodo_router version 2>/dev/null || echo "unknown")
echo "Running version: $ACTUAL_VERSION"

# Clean up tarball
rm -f "$TARBALL"

echo "=== Deploy complete ==="
