#!/bin/sh
# Preview or build the docs site without installing anything globally.
# usage: scripts/docs.sh [serve|build] [mkdocs options]   (needs uv: https://docs.astral.sh/uv/)
set -e
cd "$(dirname "$0")/.."
export NO_MKDOCS_2_WARNING=1
[ $# -eq 0 ] && set -- serve
exec uvx --with mkdocs-material mkdocs "$@"
