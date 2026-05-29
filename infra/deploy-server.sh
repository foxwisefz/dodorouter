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

  RELEASE_ROOT="$RELEASE_DIR/dodo_router"

  # Copy tarball (renamed for release_handler: unpacks <VSN>.tar.gz)
  mkdir -p "$RELEASE_ROOT/releases"
  cp "$TARBALL" "$RELEASE_ROOT/releases/${VERSION}.tar.gz"

  cd "$RELEASE_ROOT"

  # bin/upgrade calls DodoRouter.Upgrade.install/1 which starts SASL itself
  echo "Upgrading to v${VERSION}..."
  ./bin/upgrade "$VERSION"

  echo "Hot upgrade to v${VERSION} completed successfully!"
else
  echo "Service not running. Performing full install..."

  # Clear old release if any
  rm -rf "$RELEASE_DIR"/*

  # Extract full release (creates dodo_router/ inside current/)
  cd "$RELEASE_DIR"
  tar xzf "$TARBALL"

  # Start service
  systemctl --user enable dodo-router
  systemctl --user start dodo-router

  echo "Full install completed!"
fi

# Verify version
sleep 2
ACTUAL_VERSION=$("$RELEASE_DIR/dodo_router/bin/dodo_router" version 2>/dev/null || echo "unknown")
echo "Running version: $ACTUAL_VERSION"

# Clean up tarball
rm -f "$TARBALL"

echo "=== Deploy complete ==="
