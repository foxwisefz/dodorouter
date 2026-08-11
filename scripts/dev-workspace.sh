#!/usr/bin/env bash
#
# dev-workspace.sh — run several branches of DodoRouter side by side.
#
# Each workspace is a jj workspace in a sibling directory (../dodo-<name>) with
# its own port, its own Postgres database, its own test database and test port,
# and its own browser cookie jar. Nothing is shared except the secrets in the
# main repo's .envrc, which every workspace sources rather than copies.
#
#   scripts/dev-workspace.sh new <name> [-r <rev>] [--fresh] [--no-build]
#   scripts/dev-workspace.sh setup <name|all>
#   scripts/dev-workspace.sh list
#   scripts/dev-workspace.sh open <name>
#   scripts/dev-workspace.sh rm <name>
#
set -euo pipefail

# --- locate the main workspace -----------------------------------------------
# .jj/repo is a directory in the main workspace and a file pointing at it
# (relative) in every other one, which is the only reliable way back to the
# repo that holds the shared .envrc.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ -f "$here/.jj/repo" ]; then
  MAIN=$(cd "$here/.jj/$(dirname "$(cat "$here/.jj/repo")")/.." && pwd)
else
  MAIN="$here"
fi
PARENT=$(dirname "$MAIN")
ENVRC="$MAIN/.envrc"

BASE_PORT=4010        # first dev port handed out; 4000 is the main workspace
TEST_PORT_OFFSET=1000 # test server port = dev port + this

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENVRC" ] || die "no .envrc in $MAIN — copy .env.example and fill it in first"

# --- helpers -----------------------------------------------------------------
ws_path() { printf '%s/dodo-%s' "$PARENT" "$1"; }
slug() { printf '%s' "$1" | tr '[:upper:]-' '[:lower:]_' | tr -cd '[:alnum:]_'; }
db_name() { printf 'dodo_router_dev_%s' "$(slug "$1")"; }

# Read one exported value out of a workspace's .envrc without sourcing it (they
# start with a direnv `source_env`, which bash alone cannot run).
envrc_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^export $2=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$1" | tail -1
}

# Postgres credentials come from the main .envrc, which is plain exports.
load_db_env() {
  # shellcheck disable=SC1090
  set -a; . "$ENVRC"; set +a
  PGHOST=${DB_HOSTNAME:-localhost}
  PGPORT=${DB_PORT:-5432}
  PGUSER=${DB_USERNAME:-postgres}
  PGPASSWORD=${DB_PASSWORD:-postgres}
  export PGHOST PGPORT PGUSER PGPASSWORD
}

psql_admin() { psql -d postgres -v ON_ERROR_STOP=1 "$@"; }

port_in_use() { lsof -ti "tcp:$1" -sTCP:LISTEN >/dev/null 2>&1; }

# Ports already claimed by a workspace .envrc, plus the ones the main repo owns.
claimed_ports() {
  printf '4000\n4002\n'
  for f in "$PARENT"/dodo-*/.envrc; do
    [ -f "$f" ] || continue
    envrc_get "$f" PORT
  done
}

alloc_port() {
  local claimed port
  claimed=$(claimed_ports)
  port=$BASE_PORT
  while [ "$port" -lt 4100 ]; do
    if ! grep -qx "$port" <<<"$claimed" && ! port_in_use "$port"; then
      printf '%s' "$port"; return
    fi
    port=$((port + 1))
  done
  die "no free port between $BASE_PORT and 4099"
}

# --- .envrc ------------------------------------------------------------------
write_envrc() {
  local ws=$1 name=$2 port=$3 db=$4 target="$1/.envrc"

  if [ -f "$target" ] && ! grep -q '^# managed by scripts/dev-workspace.sh' "$target"; then
    cp "$target" "$target.bak"
    info "kept your old .envrc as .envrc.bak"
  fi

  cat >"$target" <<EOF
# managed by scripts/dev-workspace.sh — regenerate with:
#   $MAIN/scripts/dev-workspace.sh setup $name

# Secrets live in one place. Sourced, not copied, so rotating a key in the main
# repo reaches every workspace.
source_env ../dodo_router/.envrc

# Names the test database and suffixes every cookie we set — cookies are not
# scoped by port, so without this two dev servers on localhost clobber each
# other's login.
export DODO_WORKSPACE=$name

# Dev server.
export PORT=$port
export DB_NAME=$db
export DB_POOL_SIZE=5

# mix test in this workspace, isolated from every other one.
export TEST_PORT=$((port + TEST_PORT_OFFSET))
EOF

  if command -v direnv >/dev/null 2>&1; then
    direnv allow "$ws" >/dev/null 2>&1 || info "run 'direnv allow' in $ws yourself"
  fi
}

# --- database ----------------------------------------------------------------
db_exists() {
  [ "$(psql_admin -tAc "select 1 from pg_database where datname = '$1'")" = "1" ]
}

setup_db() {
  local db=$1 mode=$2 source_db=${DB_NAME:-dodo_router_dev}

  if db_exists "$db"; then
    info "database $db already exists — leaving it alone"
    return
  fi

  if [ "$mode" = fresh ]; then
    psql_admin -c "create database \"$db\"" >/dev/null
    info "created empty database $db"
    return
  fi

  # A template copy is instant but needs the source idle; the dev server usually
  # is not, so fall back to a dump/restore, which does not care.
  if psql_admin -c "create database \"$db\" template \"$source_db\"" >/dev/null 2>&1; then
    info "cloned $source_db -> $db (template copy)"
  else
    info "$source_db is in use — dumping it instead (this takes a moment)"
    psql_admin -c "create database \"$db\"" >/dev/null
    pg_dump --no-owner --no-privileges "$source_db" | psql -q -d "$db" >/dev/null
    info "cloned $source_db -> $db (dump/restore)"
  fi
}

drop_db() {
  psql_admin -c "drop database if exists \"$1\" with (force)" >/dev/null
}

# --- commands ----------------------------------------------------------------
cmd_new() {
  local name="" rev="" mode=clone build=1
  while [ $# -gt 0 ]; do
    case $1 in
      -r|--revision) rev=$2; shift 2 ;;
      --fresh) mode=fresh; shift ;;
      --clone) mode=clone; shift ;;
      --no-build) build=0; shift ;;
      -*) die "unknown flag $1" ;;
      *) name=$1; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: dev-workspace.sh new <name> [-r <rev>] [--fresh] [--no-build]"

  local ws; ws=$(ws_path "$name")
  [ -e "$ws" ] && die "$ws already exists — use 'setup $name' to (re)configure it"

  bold "creating workspace dodo-$name"
  if [ -n "$rev" ]; then
    (cd "$MAIN" && jj workspace add -r "$rev" "$ws")
  else
    (cd "$MAIN" && jj workspace add "$ws")
  fi

  cmd_setup "$name" "$mode" "$build"
}

cmd_setup() {
  local name=$1 mode=${2:-clone} build=${3:-1}
  local ws; ws=$(ws_path "$name")
  [ -d "$ws" ] || die "no workspace at $ws"

  local port db
  port=$(envrc_get "$ws/.envrc" PORT)
  [ -n "$port" ] || port=$(alloc_port)
  db=$(envrc_get "$ws/.envrc" DB_NAME)
  { [ -n "$db" ] && [ "$db" != dodo_router_dev ]; } || db=$(db_name "$name")

  bold "configuring dodo-$name"
  write_envrc "$ws" "$name" "$port" "$db"
  info "port $port · test port $((port + TEST_PORT_OFFSET)) · database $db"

  load_db_env
  setup_db "$db" "$mode"

  if [ "$build" = 1 ]; then
    info "fetching deps and migrating (first build takes a few minutes)"
    (cd "$ws" && direnv exec . mix deps.get >/dev/null && direnv exec . mix ecto.migrate)
  else
    info "skipped build — run 'mix deps.get && mix ecto.migrate' in $ws"
  fi

  echo
  bold "ready"
  info "cd $ws && mix phx.server"
  info "$MAIN/scripts/dev-workspace.sh open $name"
}

cmd_setup_all() {
  for d in "$PARENT"/dodo-*/; do
    d=${d%/}
    [ -e "$d/.jj" ] || continue
    cmd_setup "$(basename "$d" | sed 's/^dodo-//')" clone 0
    echo
  done
}

cmd_list() {
  printf '%-22s %-6s %-6s %-28s %s\n' WORKSPACE PORT TEST DATABASE STATE
  printf '%-22s %-6s %-6s %-28s %s\n' "$(basename "$MAIN")" 4000 4002 "${DB_NAME:-dodo_router_dev}" \
    "$(port_in_use 4000 && echo running || echo -)"
  for d in "$PARENT"/dodo-*/; do
    d=${d%/}
    [ -f "$d/.envrc" ] || continue
    local port test_port db state
    port=$(envrc_get "$d/.envrc" PORT)
    db=$(envrc_get "$d/.envrc" DB_NAME)
    test_port=$(envrc_get "$d/.envrc" TEST_PORT)
    state=$( { [ -n "$port" ] && port_in_use "$port"; } && echo running || echo - )
    [ -n "$port" ] || { port=-; state=unconfigured; }
    printf '%-22s %-6s %-6s %-28s %s\n' "$(basename "$d")" "$port" "${test_port:--}" "${db:--}" "$state"
  done
}

cmd_open() {
  local name=$1
  local ws; ws=$(ws_path "$name")
  local port; port=$(envrc_get "$ws/.envrc" PORT)
  [ -n "$port" ] || die "dodo-$name has no PORT — run 'setup $name' first"

  # A dedicated Chrome profile per workspace: separate cookie jar, separate
  # window, so several branches can be logged in at once.
  local profile="$HOME/.dodo-dev-browsers/$name"
  mkdir -p "$profile"
  open -na "Google Chrome" --args \
    --user-data-dir="$profile" \
    --no-first-run --no-default-browser-check \
    "http://localhost:$port"
  info "opened http://localhost:$port in the dodo-$name Chrome profile"
}

cmd_rm() {
  local name=$1
  local ws; ws=$(ws_path "$name")
  [ -d "$ws" ] || die "no workspace at $ws"
  local db; db=$(envrc_get "$ws/.envrc" DB_NAME)

  local test_db; test_db="dodo_router_test_$(slug "$name")"

  bold "about to delete"
  info "directory $ws"
  info "database  ${db:-none}"
  info "test db   $test_db"
  read -r -p "type the workspace name to confirm: " confirm
  [ "$confirm" = "$name" ] || die "aborted"

  (cd "$MAIN" && jj workspace forget "dodo-$name" 2>/dev/null) || true
  rm -rf "$ws"
  load_db_env
  if [ -n "$db" ]; then drop_db "$db"; fi
  drop_db "$test_db"
  info "gone"
}

case ${1:-} in
  new) shift; cmd_new "$@" ;;
  setup)
    shift
    [ $# -ge 1 ] || die "usage: dev-workspace.sh setup <name|all>"
    if [ "$1" = all ]; then cmd_setup_all; else cmd_setup "$1"; fi ;;
  list|ls) load_db_env; cmd_list ;;
  open) shift; [ $# -ge 1 ] || die "usage: dev-workspace.sh open <name>"; cmd_open "$1" ;;
  rm) shift; [ $# -ge 1 ] || die "usage: dev-workspace.sh rm <name>"; cmd_rm "$1" ;;
  *)
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    exit 1 ;;
esac
