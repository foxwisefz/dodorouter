#!/bin/bash
set -e

cd "$(dirname "$0")"

wait_healthy() {
  local port=$1
  local name=$2
  echo "Waiting for $name to be healthy..."
  for i in {1..30}; do
    if curl -sf "http://localhost:$port/health" > /dev/null 2>&1; then
      echo "$name is healthy!"
      return 0
    fi
    echo "Waiting... ($i/30)"
    sleep 2
  done
  echo "ERROR: $name didn't become healthy"
  return 1
}

echo "=== Zero-downtime deploy ==="
echo ""

echo "Pulling latest image..."
docker compose pull

echo ""
echo "=== Rolling update: app1 ==="
docker compose up -d --no-deps app1
wait_healthy 4001 "app1"

echo ""
echo "=== Rolling update: app2 ==="
docker compose up -d --no-deps app2
wait_healthy 4002 "app2"

echo ""
echo "=== Deploy complete! ==="
