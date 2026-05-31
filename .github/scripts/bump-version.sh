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

# Generate fresh appup.ex with empty instructions
# (Developers should manually add module changes when needed)
cat > "$APPUP_FILE" << EOF
# Appup file for DodoRouter
# This describes how to upgrade the application between versions
# Castle's :appup compiler reads this and copies it into the release ebin directory
# Format: {NewVsn, [{OldVsn, [Instructions]}], [{OldVsn, [Instructions]}]}
#
# Instructions:
#   {load_module, Module} - reload a changed module
#   {update, Module, {advanced, []}} - update a GenServer/Agent and call code_change/3
#   {add_module, Module} - add a new module
#   {delete_module, Module} - remove a deleted module

{
  ~c"${NEW_VERSION}",
  [
    {~c"${CURRENT_VERSION}", []}
  ],
  [
    {~c"${CURRENT_VERSION}", []}
  ]
}
EOF

echo "Bumped version: ${CURRENT_VERSION} -> ${NEW_VERSION}"

# Configure git and commit
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$MIX_FILE" "$APPUP_FILE"
git commit -m "Bump version to ${NEW_VERSION} [skip ci]"
git push

echo "$NEW_VERSION"
