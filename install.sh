#!/usr/bin/env bash
# Kept for backwards compatibility: install.sh now simply hands over to
# deploy.sh, which is the single supported entry point in this fork.
set -Eeuo pipefail
cd -- "$(dirname -- "$0")"
exec ./deploy.sh "$@"
