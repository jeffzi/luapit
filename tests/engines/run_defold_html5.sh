#!/usr/bin/env bash
set -euo pipefail

# Integration test runner for the Defold HTML5 engine adapter.
# Checks for java, bob.jar, node, and playwright before running.

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

command -v node >/dev/null || {
  printf "SKIP: node not found in PATH\n"
  exit 0
}

node -e "require('playwright')" 2>/dev/null || {
  printf "SKIP: playwright not installed (run: npm install playwright && npx playwright install chromium)\n"
  exit 0
}

command -v luapit >/dev/null || {
  printf "ERROR: luapit not found in PATH (run 'luarocks make' first)\n" >&2
  exit 1
}

command -v luapit-html5-harness >/dev/null || {
  printf "ERROR: luapit-html5-harness not found in PATH (run 'luarocks make' first)\n" >&2
  exit 1
}

printf "Running Defold HTML5 integration test...\n"
luapit . -R defold-html5 -b tests/engines/fixtures/ -t

printf "PASS: Defold HTML5 integration test succeeded\n"
