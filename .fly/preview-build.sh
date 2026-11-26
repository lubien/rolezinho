#!/usr/bin/env bash
# Build step for Fly.io PR previews (see preview.yml). Runs once per commit.
set -euo pipefail

if ! compgen -G "/usr/lib/postgresql/*/bin/postgres" > /dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql
fi

export MIX_ENV=dev
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
mix assets.setup
mix compile
mix assets.build
