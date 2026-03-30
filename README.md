# LuaPit

[![CI](https://github.com/jeffzi/luapit/actions/workflows/busted.yml/badge.svg)](https://github.com/jeffzi/luapit/actions/workflows/busted.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/jeffzi/luapit)](https://luarocks.org/modules/jeffzi/luapit)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Lua: 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)

Pit Lua library versions against each other.

LuaPit runs [LuaMark](https://github.com/jeffzi/luamark) benchmarks across git refs, tags,
branches, or local directories and prints a comparison table with median times, confidence
intervals, and rankings. Each version runs in isolation so modules never leak across targets.

## Quick example

```sh
luapit ref .#main .#feature -b benchmarks/
```

This compares the library at the `main` and `feature` git refs, using every `*_bench.lua` file
found under `benchmarks/`. Each target gets a temporary clone; the originals are untouched.

## Installation

Requires Lua >= 5.1.

```sh
luarocks install luapit
```

Or from a local clone:

```sh
luarocks make luapit-dev-1.rockspec
```

LuaRocks pulls in the dependencies automatically.

## Usage

LuaPit provides one command: `ref`.

### The `ref` command

```text
luapit ref <targets...> [options]
```

| Option                   | Description                                                            | Default                 |
| ------------------------ | ---------------------------------------------------------------------- | ----------------------- |
| `<targets>`              | One or more target specifiers (positional, required).                  |                         |
| `-b, --bench <path>`     | Benchmark files or directories (repeatable).                           | `.` (current directory) |
| `-R, --runtime <name>`   | Lua runtime to run benchmarks under (name or path).                    | auto-detected           |
| `-o, --output <path>`    | Write results to a JSON file.                                          |                         |
| `-t, --test`             | Test mode: run 1 round per benchmark for a quick smoke test.           | off                     |
| `-p, --param NAME:VALUE` | Pass a parameter to LuaMark (repeatable).                              |                         |
| `--filter <pattern>`     | Filter benchmarks by Lua pattern (repeatable, OR logic).               | none (run all)          |
| `--prepare <cmd>`        | Shell command to run in each cloned target dir before benchmarking.    | none                    |
| `--lua-path <subdir>`    | Subdirectory within each target to add to `package.path` (repeatable). | target root             |

### Target specifiers

A target tells LuaPit where to find a version of the library to benchmark:

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

Use aliases when two targets would otherwise share a display name. The bare `.` resolves to the
git repository root, or the current directory if not inside a git repo.

Remote targets use a shallow clone when possible (branches and tags). Commit hashes fall back to
a full clone. LuaPit removes all temporary clones when the run finishes.

### Prepare hook

`--prepare` runs a shell command inside each cloned target directory before benchmarking starts.
This is useful for compile-to-Lua projects (TypeScript-to-Lua, Fennel, MoonScript, Teal) where
the repository contains source files but no `.lua` output.

```sh
luapit ref .#main .#feature -b benchmarks/ \
   --prepare "npm ci && npx tstl -p tsconfig.benchmarks.json"
```

The command runs only in cloned targets (those created from `repo#ref` specifiers). Working tree
(`.`) and local directory targets are used as-is.

If the command fails for a target, LuaPit prints a warning, removes that target, and continues
with the rest.

### Custom Lua path

By default, LuaPit prepends each target's root directory to `package.path`. If your Lua files
live in a subdirectory (common with compile-to-Lua toolchains), use `--lua-path` to override.

```sh
# Transpiled Lua output lives in lua/ within each target
luapit ref .#main .#feature -b lua/benchmarks/ --lua-path lua \
   --prepare "npm ci && npx tstl -p tsconfig.benchmarks.json"
```

`--lua-path` replaces the default root entry. To include both the root and a subdirectory, pass
both:

```sh
luapit ref .#main -b bench/ --lua-path . --lua-path lua
```

Each path is relative to the target directory, so multi-ref comparisons resolve `require` calls
against each target's own copy.

### Benchmark files

LuaPit discovers files matching `*_bench.lua`. Pass a directory to `-b` and it searches
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

- `before` — called once before timing starts; its return value is passed to `fn` as the first
  argument.
- `after` — called once after timing finishes; receives `(ctx, params)` where `ctx` is the value
  returned by `before`.
- `baseline` — set to `true` to mark this spec as the reference for ratio calculations. When set,
  all ratios in the group are computed relative to this spec's median. Without a baseline, ratios
  are relative to the fastest spec.

### Target isolation

For each target, LuaPit prepends the target's directory (or `--lua-path` subdirectories) to
`package.path` before loading the benchmark. When you write `require("mylib")`, it resolves
against that target's code. `package.loaded` is restored between targets so modules never leak
across versions.

### Filtering benchmarks

`--filter` accepts Lua patterns and matches against the benchmark ID. The ID is the relative file
path (without the `_bench.lua` suffix), plus `::spec_name` for named-specs.

Multiple filters use OR logic: a benchmark runs if it matches any pattern.

```sh
# Run only benchmarks whose ID contains "sort" or "insert"
luapit ref .#main .#dev -b bench/ --filter sort --filter insert
```

### Parameters

`-p NAME:VALUE` forwards parameters to LuaMark. Values are auto-coerced: numeric strings become
numbers, `true`/`false` become booleans, and everything else stays a string.

Repeat `-p` with the same name to pass multiple values, which LuaMark receives as an array:

```sh
luapit ref .#main .#dev -b bench/ -p size:100 -p size:10000
```

### Runtimes

Benchmarks always run in a subprocess. Without `-R`, LuaPit auto-detects the current Lua
interpreter. With `-R`, it uses the specified runtime — either a name resolved from PATH or an
absolute path.

| Runtime          | `-R` value     | Binary resolved     | Notes                         |
| ---------------- | -------------- | ------------------- | ----------------------------- |
| LuaJIT           | `luajit`       | `luajit`            |                               |
| Lua              | `lua`          | `lua`               | Any Lua interpreter           |
| Love2D           | `love`         | `love`              | Game framework, runs headless |
| Defold (desktop) | `defold`       | `dmengine_headless` | Game engine                   |
| Defold (HTML5)   | `defold-html5` | `node`              | Game engine, browser/WASM     |

### Game engine runtimes

These runtimes scaffold a temporary engine project, copy your benchmarks and dependencies into
it, and run the engine in headless mode.

**Love2D** (`-R love`)

Requires `love` on PATH. LuaPit creates a temporary Love2D project with graphics, audio, and
input modules disabled and runs benchmarks through `love.load()`. Use this to benchmark code that
depends on Love2D APIs such as `love.math`.

**Defold** (`-R defold`)

Requires `dmengine_headless` and `java` on PATH, plus `bob.jar` (either set the `BOB` environment
variable to the jar path or place it on PATH). LuaPit scaffolds a minimal Defold project, builds
it with bob.jar, and launches the headless engine.

**Defold HTML5** (`-R defold-html5`)

Same prerequisites as Defold, plus [Node.js](https://nodejs.org/) and Playwright:

```sh
npx playwright install chromium
```

Builds for the `js-web` platform and runs benchmarks in headless Chromium via a Playwright
harness.

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
| `version`                      | LuaPit version that produced the file.                                      |
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
