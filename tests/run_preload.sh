#!/bin/bash
# Run a binary under LD_PRELOAD with the dataplane intercept library.
export LD_PRELOAD="${1:?Usage: $0 <libpath> <binary> [args...]}"
shift
exec "$@"
