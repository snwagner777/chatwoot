#!/bin/sh
# Based on railwayapp-templates/chatwoot at 20ca56b9f98e36aa2d8c6f600fda4003cd9fd0c2.
# The Railway template's MIT notice is retained in railway.LICENSE.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

export RAILS_ENV="${RAILS_ENV:-production}"
export NODE_ENV="${NODE_ENV:-production}"
export PORT="${PORT:-3000}"
: "${REDIS_URL:?REDIS_URL must be configured}"
: "${SECRET_KEY_BASE:?SECRET_KEY_BASE must be configured}"

case "$PORT" in
  ''|*[!0-9]*) echo 'PORT must be a valid TCP port' >&2; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo 'PORT must be a valid TCP port' >&2
  exit 1
fi

mkdir -p tmp/pids storage
rm -f tmp/pids/server.pid

# No shell tracing: connection strings and keys must never enter startup logs.
bundle exec ruby docker/entrypoints/railway_wait_for_db.rb
# On the pinned 4.18.0 release this task already invokes migrations.
bundle exec rails db:chatwoot_prepare

# Keep the template's web + worker model and fail-closed exit behavior.
# Forward container shutdown and wait for both children via multirun.
supervisor_pid=
terminate() {
  trap '' TERM INT
  if [ -n "$supervisor_pid" ]; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" || true
  fi
  exit 1
}
trap terminate TERM INT
multirun \
  "bundle exec sidekiq -C config/sidekiq.yml" \
  "bundle exec rails s -b 0.0.0.0 -p $PORT" &
supervisor_pid=$!
wait "$supervisor_pid"
# Like the official template's final false, a clean child exit must still
# restart the service under Railway's ON_FAILURE policy.
exit 1
