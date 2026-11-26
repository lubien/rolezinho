#!/usr/bin/env bash
# Build step for Fly.io PR previews (see preview.yml). Runs once per commit.
set -euxo pipefail

if ! compgen -G "/usr/lib/postgresql/*/bin/postgres" > /dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql
fi

# The preview image resolves Erlang/Elixir through mise, which honors the
# repo's .tool-versions; install those exact versions before calling mix.
# Erlang may be compiled from source, which needs these headers.
if command -v mise > /dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential autoconf libncurses-dev libssl-dev
  mise install
fi

export MIX_ENV=dev
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
mix assets.setup
mix compile
mix assets.build
