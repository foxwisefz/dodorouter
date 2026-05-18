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
  
  # Backup only the core release directories (not .env, logs, etc)
  BACKUP_DIR="${RELEASE_DIR}.backup.$(date +%s)"
  mkdir -p "$BACKUP_DIR"
  cp -r "$RELEASE_DIR/bin" "$BACKUP_DIR/" 2>/dev/null || true
  cp -r "$RELEASE_DIR/erts"* "$BACKUP_DIR/" 2>/dev/null || true
  cp -r "$RELEASE_DIR/lib" "$BACKUP_DIR/" 2>/dev/null || true
  cp -r "$RELEASE_DIR/releases" "$BACKUP_DIR/" 2>/dev/null || true
  echo "Backup created at $BACKUP_DIR"
  
  # Copy upgrade tarball to releases directory
  mkdir -p "$RELEASE_DIR/releases"
  cp "$TARBALL" "$RELEASE_DIR/releases/dodo_router-${VERSION}.tar.gz"
  
  # Perform hot upgrade via rpc
  if "$RELEASE_DIR/bin/upgrade" "$VERSION"; then
    echo "Hot upgrade to v${VERSION} completed successfully!"
    
    # Clean up old backups (keep last 3)
    ls -td ${RELEASE_DIR}.backup.* 2>/dev/null | tail -n +4 | xargs -r rm -rf
  else
    echo "ERROR: Hot upgrade failed! Rolling back..."
    # Restore only core directories, leave .env and other files alone
    rm -rf "$RELEASE_DIR/bin" "$RELEASE_DIR/erts"* "$RELEASE_DIR/lib" "$RELEASE_DIR/releases"
    cp -r "$BACKUP_DIR/"* "$RELEASE_DIR/"
    rm -rf "$BACKUP_DIR"
    systemctl --user restart dodo-router
    exit 1
  fi
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
