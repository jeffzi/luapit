# LuaBench

[![CI](https://github.com/jeffzi/luabench/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luabench/actions/workflows/busted.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Lua: 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)

CLI companion to [LuaMark](https://github.com/jeffzi/luamark) for comparing Lua
library performance across git references.

LuaBench runs [LuaMark](https://github.com/jeffzi/luamark) benchmarks against one or
more versions of a Lua library (git refs, tags, branches, or local directories) and
prints a comparison table with median times, confidence intervals, and rankings. Each
version runs in isolation, preventing shared-state contamination.

In addition to standard Lua interpreters, it supports Love2D and Defold runtimes for
benchmarking code that depends on engine-specific APIs.

**Status:** Under development. Not yet published to luarocks.

## Quick example

```sh
luabench ref .#main .#feature -b benchmarks/
```

This compares the library at the `main` and `feature` git refs, using every `*_bench.lua`
file found under `benchmarks/`. Each target gets a temporary clone; the originals are
untouched.

## Installation

Requires Lua >= 5.1.

```sh
luarocks install https://raw.githubusercontent.com/jeffzi/luabench/main/luabench-dev-1.rockspec
```

Or from a local clone:

```sh
luarocks make luabench-dev-1.rockspec
```

LuaRocks pulls in the dependencies automatically.

## Usage

LuaBench provides one command: `ref`.

### The `ref` command

```text
luabench ref <targets...> [options]
```

| Option                   | Description                                                            | Default                 |
| ------------------------ | ---------------------------------------------------------------------- | ----------------------- |
| `<targets>`              | One or more target specifiers (positional, required).                  |                         |
| `-b, --bench <path>`     | Benchmark files or directories (repeatable).                           | `.` (current directory) |
| `-R, --runtime <name>`   | Run benchmarks under a different Lua runtime.                          | same process            |
| `-o, --output <path>`    | Write results to a JSON file.                                          |                         |
| `-t, --test`             | Test mode: run 1 round per benchmark for a quick smoke test.           | off                     |
| `-p, --param NAME:VALUE` | Pass a parameter to LuaMark (repeatable).                              |                         |
| `--filter <pattern>`     | Filter benchmarks by Lua pattern (repeatable, OR logic).               | none (run all)          |
| `--prepare <cmd>`        | Shell command to run in each cloned target dir before benchmarking.    | none                    |
| `--lua-path <subdir>`    | Subdirectory within each target to add to `package.path` (repeatable). | target root             |

### Target specifiers

A target tells LuaBench where to find a version of the library to benchmark. The general
format is:

```text
[alias=][repo]#ref
```

| Form                     | Example                             | Display name   |
| ------------------------ | ----------------------------------- | -------------- |
| Local repo + ref         | `.#main`                            | `main`         |
| Local repo + ref + alias | `v1=.#v1.0.0`                       | `v1`           |
| HTTPS remote + ref       | `https://github.com/user/repo#v2.0` | `v2.0`         |
| SSH remote + ref         | `git@github.com:user/repo#dev`      | `dev`          |
| Existing local directory | `/path/to/lib` or `./lib`           | `lib`          |
| Bare dot (working tree)  | `.`                                 | `working-tree` |

Aliases disambiguate targets that would otherwise share a display name. The bare `.`
resolves to the git repository root, or the current directory if not inside a git repo.

Remote targets use a shallow clone when possible (branches and tags). Commit hashes fall
back to a full clone. LuaBench removes all temporary clones when the run finishes.

### Prepare hook

`--prepare` runs a shell command inside each cloned target directory before benchmarking
starts. This is useful for projects that compile to Lua (TypeScript-to-Lua, Fennel,
MoonScript, Teal) where the repository contains source files but no `.lua` output.

```sh
luabench ref .#main .#feature -b benchmarks/ \
   --prepare "npm ci && npx tstl -p tsconfig.benchmarks.json"
```

The command runs only in cloned targets (those created from `repo#ref` specifiers). Working
tree (`.`) and local directory targets are used as-is.

If the command fails for a target, LuaBench prints a warning, removes that target, and
continues with the remaining targets. Output from the command streams directly to the
terminal so build errors are visible.

### Custom Lua path

By default, LuaBench prepends each target's root directory to `package.path`. If your
project's Lua files live in a subdirectory (common with compile-to-Lua toolchains),
use `--lua-path` to tell LuaBench where to look instead.

```sh
# Transpiled Lua output lives in lua/ within each target
luabench ref .#main .#feature -b lua/benchmarks/ --lua-path lua \
   --prepare "npm ci && npx tstl -p tsconfig.benchmarks.json"
```

`--lua-path` replaces the default root entry. To include both the root and a
subdirectory, pass both:

```sh
luabench ref .#main -b bench/ --lua-path . --lua-path lua
```

Each path is relative to the target directory, so multi-ref comparisons work correctly
— each cloned ref resolves `require` calls against its own copy of the subdirectory.

### Benchmark files

LuaBench discovers files matching `*_bench.lua`. Pass a directory to `-b` and it searches
recursively, or pass individual file paths.

A benchmark file returns a table in one of two formats.

**Single-spec** (one benchmark per file):

```lua
local mylib = require("mylib")

return {
   fn = function()
      mylib.sort(data)
   end,
}
```

**Named-specs** (multiple benchmarks per file):

```lua
local mylib = require("mylib")

return {
   insert = {
      fn = function()
         mylib.insert(data, value)
      end,
   },
   remove = {
      fn = function()
         mylib.remove(data, key)
      end,
   },
}
```

Each spec is a LuaMark spec table. Beyond `fn`, you can use:

- `before` — called once before timing starts; its return value is passed to `fn` as the
  first argument.
- `after` — called once after timing finishes; receives `(ctx, params)` where `ctx` is the
  value returned by `before`.
- `baseline` — set to `true` to mark this spec as the reference for ratio calculations.
  When set, all ratios in the group are computed relative to this spec's median. Without a
  baseline, ratios are relative to the fastest spec.

**Target isolation.** For each target, LuaBench prepends the target's directory to
`package.path` before loading the benchmark (or the subdirectories specified by
`--lua-path`). When you write `require("mylib")`, it resolves against that target's
code. `package.loaded` is restored between targets so modules do not leak across
versions.

### Filtering benchmarks

`--filter` accepts Lua patterns and matches against the benchmark ID. The ID is the
relative file path (without the `_bench.lua` suffix), plus `::spec_name` for named-specs.

Multiple filters use OR logic: a benchmark runs if it matches any pattern.

```sh
# Run only benchmarks whose ID contains "sort" or "insert"
luabench ref .#main .#dev -b bench/ --filter sort --filter insert
```

### Parameters

`-p NAME:VALUE` forwards parameters to LuaMark. Values are auto-coerced: numeric strings
become numbers, `true`/`false` become booleans, and everything else stays a string.

Repeat `-p` with the same name to pass multiple values, which LuaMark receives as an
array:

```sh
luabench ref .#main .#dev -b bench/ -p size:100 -p size:10000
```

### Runtimes

Without `-R`, benchmarks run in the same Lua process as LuaBench itself.

With `-R`, benchmarks run in a subprocess under the specified runtime. The value can be a
name resolved from PATH or an absolute path to the binary.

| Runtime          | `-R` value     | Binary resolved     | Notes                         |
| ---------------- | -------------- | ------------------- | ----------------------------- |
| LuaJIT           | `luajit`       | `luajit`            |                               |
| Lua              | `lua`          | `lua`               | Any Lua interpreter           |
| Love2D           | `love`         | `love`              | Game framework, runs headless |
| Defold (desktop) | `defold`       | `dmengine_headless` | Game engine                   |
| Defold (HTML5)   | `defold-html5` | `node`              | Game engine, browser/WASM     |

### Game engine runtimes

These runtimes scaffold a temporary engine project, copy your benchmarks and dependencies
into it, and run the engine in headless mode.

**Love2D** (`-R love`)

Requires `love` on PATH. LuaBench creates a temporary Love2D project with graphics,
audio, and input modules disabled and runs benchmarks through `love.load()`. Use this to
benchmark code that depends on Love2D APIs such as `love.math`.

**Defold** (`-R defold`)

Requires `dmengine_headless` and `java` on PATH, plus `bob.jar` (either set the `BOB`
environment variable to the jar path or place it on PATH). LuaBench scaffolds a minimal
Defold project, builds it with bob.jar, and launches the headless engine.

**Defold HTML5** (`-R defold-html5`)

Same prerequisites as Defold, plus [Node.js](https://nodejs.org/) and Playwright:

```sh
npx playwright install chromium
```

Builds for the `js-web` platform and runs benchmarks in headless Chromium via a
Playwright harness.

### JSON output

`-o` writes results to a JSON file with a metadata envelope:

```json
{
  "version": "0.5.0",
  "timestamp": "2026-03-21T12:00:00Z",
  "targets": [
    { "name": "main", "spec": ".#main" },
    { "name": "feature", "spec": ".#feature" }
  ],
  "results": [
    {
      "file": "benchmarks/sort",
      "spec": "default",
      "targets": [
        {
          "name": "main",
          "median": 0.00015,
          "ci_lower": 0.00014,
          "ci_upper": 0.00016,
          "rounds": 1000,
          "rank": 2,
          "ratio": 1.25
        },
        {
          "name": "feature",
          "median": 0.00012,
          "ci_lower": 0.00011,
          "ci_upper": 0.00013,
          "rounds": 1000,
          "rank": 1,
          "ratio": 1.0
        }
      ]
    }
  ]
}
```

| Field                          | Description                                                                 |
| ------------------------------ | --------------------------------------------------------------------------- |
| `version`                      | LuaBench version that produced the file.                                    |
| `timestamp`                    | UTC timestamp of the run.                                                   |
| `targets[].name`               | Display name of each target.                                                |
| `targets[].spec`               | Original target specifier string.                                           |
| `results[].file`               | Relative benchmark path (without `_bench.lua` suffix).                      |
| `results[].spec`               | Spec name, or `"default"` for single-spec files.                            |
| `results[].targets[].median`   | Median execution time in seconds.                                           |
| `results[].targets[].ci_lower` | Lower bound of the confidence interval.                                     |
| `results[].targets[].ci_upper` | Upper bound of the confidence interval.                                     |
| `results[].targets[].rounds`   | Number of timed rounds executed.                                            |
| `results[].targets[].rank`     | Rank among targets (1 = fastest).                                           |
| `results[].targets[].ratio`    | Time relative to the baseline, or the fastest target if no baseline is set. |

## License

[MIT](LICENSE)
