#!/usr/bin/env bash
# Start step for Fly.io PR previews (see preview.yml). Runs on every boot of
# the preview Sprite, including wake-ups after it sleeps, so it must be safe to
# run repeatedly: it never wipes data the reviewer created.
set -euxo pipefail

# Sprite language runtimes live here; the step may not run in a login shell.
export PATH="/.sprite/bin:$PATH"

export MIX_ENV=dev
export PORT="${PORT:-8080}"

pg_version=$(basename "$(ls -d /usr/lib/postgresql/*/ | sort -V | tail -n1)")

# /var/run is a tmpfs, so the socket directory is gone after every restart.
sudo install -d -o postgres -g postgres -m 2775 /var/run/postgresql

if ! pg_isready -q -h localhost; then
  sudo pg_ctlcluster "$pg_version" main start
fi

until pg_isready -q -h localhost; do sleep 1; done

# config/dev.exs connects as postgres/postgres over TCP.
sudo -u postgres psql -q -c "ALTER USER postgres PASSWORD 'postgres'"

# Seeds wipe the events table, so only run them when the database is new.
if sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw rolezinho_dev; then
  mix ecto.migrate
else
  mix ecto.setup
fi

exec mix phx.server
