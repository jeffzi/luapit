#!/usr/bin/env bash
set -euo pipefail

# Integration test runner for the Love2D engine adapter.
# Checks for the love binary, then runs luabench in test mode.

command -v love >/dev/null || {
	printf "SKIP: love not found in PATH\n"
	exit 0
}

command -v luabench >/dev/null || {
	printf "ERROR: luabench not found in PATH (run 'luarocks make' first)\n" >&2
	exit 1
}

printf "Running Love2D integration test...\n"
luabench ref . -R love -b tests/engines/fixtures/ -t

printf "PASS: Love2D integration test succeeded\n"
