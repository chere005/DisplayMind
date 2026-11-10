#!/bin/sh
# Test, deploy, tag, push: full tools/preflight.sh, then commit, tag vX.Y.0,
# atomic push, install. See tools/release-lib.sh. Option: --dry-run.
set -eu
LANE=tdtp
. "$(dirname "$0")/release-lib.sh"
release_main "$@"
