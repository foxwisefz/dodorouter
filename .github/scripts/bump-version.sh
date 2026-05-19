#!/bin/bash
set -euo pipefail

# Bump the patch version in mix.exs
# Usage: ./bump-version.sh

MIX_FILE="mix.exs"

# Extract current version
CURRENT_VERSION=$(grep -E '^\s+version:\s+"[0-9]+\.[0-9]+\.[0-9]+",' "$MIX_FILE" | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')

if [ -z "$CURRENT_VERSION" ]; then
  echo "ERROR: Could not find version in $MIX_FILE"
  exit 1
fi

# Split into major.minor.patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump patch
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"

# Update mix.exs
sed -i.bak -E "s/(version: \")${CURRENT_VERSION}(\",)/\1${NEW_VERSION}\2/" "$MIX_FILE"
rm -f "$MIX_FILE.bak"

# Update appup.ex
APPUP_FILE="appup.ex"
if [ -f "$APPUP_FILE" ]; then
  sed -i.bak -E "1s/~c\"${CURRENT_VERSION}\"/~c\"${NEW_VERSION}\"/" "$APPUP_FILE"
  rm -f "$APPUP_FILE.bak"
  echo "Updated appup version: ${CURRENT_VERSION} -> ${NEW_VERSION}"
fi

echo "Bumped version: ${CURRENT_VERSION} -> ${NEW_VERSION}"

# Configure git and commit
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$MIX_FILE"
if [ -f "$APPUP_FILE" ]; then
  git add "$APPUP_FILE"
fi
git commit -m "Bump version to ${NEW_VERSION} [skip ci]"
git push

echo "$NEW_VERSION"
