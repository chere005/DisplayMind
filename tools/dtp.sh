#!/bin/sh
# Deploy, tag, push: build + --diagnostics + watchdog check (no full suite),
# then commit, tag vX.Y.0, atomic push, install. See tools/release-lib.sh.
# Option: --dry-run.
set -eu
LANE=dtp
. "$(dirname "$0")/release-lib.sh"
release_main "$@"
