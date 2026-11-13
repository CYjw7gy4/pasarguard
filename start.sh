#!/bin/sh
# PasarGuard startup wrapper: remove any stale runtime patch overrides so the
# clean image code is always authoritative, then hand over to entrypoint.sh.
set -eu
rm -rf /persistent/patch
exec sh /home/container/entrypoint.sh
