#!/usr/bin/env bash
set -euo pipefail

# Integration test runner for the Defold engine adapter.
# Checks for dmengine_headless, java, and bob.jar before running.

command -v dmengine_headless >/dev/null || {
  printf "SKIP: dmengine_headless not found in PATH\n"
  exit 0
}

command -v java >/dev/null || {
  printf "SKIP: java not found in PATH\n"
  exit 0
}

if [[ -z "${BOB:-}" ]]; then
  command -v bob.jar >/dev/null || {
    printf "SKIP: bob.jar not found (set BOB env var or add to PATH)\n"
    exit 0
  }
fi

command -v luapit >/dev/null || {
  printf "ERROR: luapit not found in PATH (run 'luarocks make' first)\n" >&2
  exit 1
}

printf "Running Defold integration test...\n"
luapit . -R defold -b tests/engines/fixtures/ -t

printf "PASS: Defold integration test succeeded\n"
