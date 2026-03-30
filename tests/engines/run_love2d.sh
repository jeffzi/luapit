#!/usr/bin/env bash
set -euo pipefail

# Integration test runner for the Love2D engine adapter.
# Checks for the love binary, then runs luapit in test mode.

command -v love >/dev/null || {
  printf "SKIP: love not found in PATH\n"
  exit 0
}

command -v luapit >/dev/null || {
  printf "ERROR: luapit not found in PATH (run 'luarocks make' first)\n" >&2
  exit 1
}

printf "Running Love2D integration test...\n"
luapit ref . -R love -b tests/engines/fixtures/ -t

printf "PASS: Love2D integration test succeeded\n"
