#!/usr/bin/env bash
# Back-compat shim: the wiring atlas now renders through the generic atlas
# viewer (linux/scripts/atlas-serve.sh + docs/linux-port/atlas/viewer.html).
# Kept so existing muscle memory / docs links keep working.
exec "$(dirname "$0")/atlas-serve.sh" wiring "$@"
