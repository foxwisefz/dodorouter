#!/bin/bash
set -euo pipefail

# Bump the patch version based on the latest git tag, update mix.exs and appup.ex
# Usage: ./bump-version.sh
# Does NOT commit or push — the caller is responsible for that if needed.

MIX_FILE="mix.exs"
APPUP_FILE="appup.ex"

# Find the latest version from git tags (not mix.exs, which may be stale)
LATEST_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

if [ -z "$LATEST_TAG" ]; then
  echo "ERROR: No version tags found"
  exit 1
fi

CURRENT_VERSION="${LATEST_TAG#v}"
echo "Latest released version: ${CURRENT_VERSION} (from tag ${LATEST_TAG})"

# Split into major.minor.patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump patch
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"

# Update mix.exs (replace whatever version is there)
sed -i.bak -E "s/(version: \")[0-9]+\.[0-9]+\.[0-9]+(\",)/\1${NEW_VERSION}\2/" "$MIX_FILE"
rm -f "$MIX_FILE.bak"

# Generate appup.ex automatically from git diff
if command -v elixir >/dev/null 2>&1; then
  echo "Generating appup.ex from changed modules..."
  elixir scripts/generate_appup.exs "$CURRENT_VERSION" "$NEW_VERSION" > "$APPUP_FILE"
else
  echo "WARNING: elixir not available, generating empty appup.ex"
  cat > "$APPUP_FILE" << EOF
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
fi

echo "Bumped version: ${CURRENT_VERSION} -> ${NEW_VERSION}"
echo "$NEW_VERSION"
