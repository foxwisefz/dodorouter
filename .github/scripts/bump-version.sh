#!/bin/bash
set -euo pipefail

# Bump the patch version in mix.exs and update appup.ex
# Usage: ./bump-version.sh

MIX_FILE="mix.exs"
APPUP_FILE="appup.ex"

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

# Update appup.ex - change top version and add new entry
if [ -f "$APPUP_FILE" ]; then
  # Create temp file with new version and entry
  cat > /tmp/appup_new.txt << EOF
{
  ~c"${NEW_VERSION}",
  [
    {~c"${CURRENT_VERSION}", []},
EOF
  
  # Extract the old upgrade entries (skip first line and first entry)
  sed -n '6,$p' "$APPUP_FILE" | sed '1,/^  ],$/d' | sed '1,/^  \[$/d' | sed '/^  ]$/,$d' > /tmp/appup_old_entries.txt
  
  # Build new appup file
  cat /tmp/appup_new.txt > "$APPUP_FILE"
  cat /tmp/appup_old_entries.txt >> "$APPUP_FILE"
  
  # Add closing brackets and downgrade section
  cat >> "$APPUP_FILE" << EOF
  ],
  [
    {~c"${CURRENT_VERSION}", []},
EOF
  
  # Add old downgrade entries
  sed -n '/^  ],$/,$p' "$APPUP_FILE.bak" 2>/dev/null | tail -n +2 | sed '/^}$/d' >> "$APPUP_FILE" || true
  
  # Add final closing bracket
  echo "}" >> "$APPUP_FILE"
  
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
