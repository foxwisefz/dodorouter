#!/bin/bash
set -euo pipefail

VERSION=$1
RELEASE_DIR="/opt/dodo-router"
TARBALL="/tmp/dodo-router-${VERSION}.tar.gz"

if [ ! -f "$TARBALL" ]; then
  echo "ERROR: Release tarball not found: $TARBALL"
  exit 1
fi

echo "=== Deploying dodo-router v${VERSION} ==="

# Ensure release directory exists
mkdir -p "$RELEASE_DIR"

# Check if service is currently running
if systemctl is-active --quiet dodo-router; then
  echo "Service is running. Performing hot upgrade..."
  
  # For hot upgrades, extract to the releases subdirectory
  # The release tarball contains the full release, but we can use it for upgrade
  # by extracting it and then running the upgrade command
  
  # Backup current release
  BACKUP_DIR="${RELEASE_DIR}.backup.$(date +%s)"
  cp -r "$RELEASE_DIR" "$BACKUP_DIR"
  echo "Backup created at $BACKUP_DIR"
  
  # Extract new release over existing one
  # Note: This is safe because the BEAM VM keeps files in memory
  cd "$RELEASE_DIR"
  tar xzf "$TARBALL" --overwrite
  
  # Perform hot upgrade
  if "$RELEASE_DIR/bin/dodo_router" upgrade "$VERSION"; then
    echo "Hot upgrade to v${VERSION} completed successfully!"
    
    # Clean up old backups (keep last 3)
    ls -td ${RELEASE_DIR}.backup.* 2>/dev/null | tail -n +4 | xargs -r rm -rf
  else
    echo "ERROR: Hot upgrade failed! Rolling back..."
    rm -rf "$RELEASE_DIR"
    mv "$BACKUP_DIR" "$RELEASE_DIR"
    systemctl restart dodo-router
    exit 1
  fi
else
  echo "Service not running. Performing full install..."
  
  # Extract full release
  cd "$RELEASE_DIR"
  tar xzf "$TARBALL"
  
  # Ensure proper permissions
  chown -R dodo-router:dodo-router "$RELEASE_DIR"
  
  # Start service
  systemctl enable dodo-router
  systemctl start dodo-router
  
  echo "Full install completed!"
fi

# Clean up tarball
rm -f "$TARBALL"

echo "=== Deploy complete ==="
