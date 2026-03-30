# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-03-30

### Added

- `--lua-path` option to add subdirectories within each target to `package.path` (repeatable),
  for projects where Lua files live under a subdirectory (e.g., `--lua-path lua`)
- `--prepare` hook to run a shell command in each cloned target directory before benchmarking
  (e.g., compile TypeScript-to-Lua or Fennel sources)
- Love2D runtime (`-R love`): runs benchmarks in a headless Love2D project for code that depends
  on Love2D APIs
- Defold runtime (`-R defold`): builds a minimal Defold project and runs benchmarks via the
  headless engine
- Defold HTML5 runtime (`-R defold-html5`): builds for the `js-web` platform and runs benchmarks
  in headless Chromium via Playwright
- Windows support: run benchmarks on Windows
- Per-target status lines printed as each benchmark completes

### Changed

- Project renamed from LuaBench to **LuaPit** — package, module paths, CLI binary, and repository
  URL all updated

### Removed

- Progress bar

### Fixed

- Ctrl-C during a benchmark run now exits immediately instead of being ignored
- Incomplete target spec (e.g., `#sha`) now shows a helpful error with the correct format instead
  of a generic message
- Malformed benchmark specs (named specs without an `fn` function) now warn and skip instead of
  exiting with an error

## [0.4.0] - 2026-03-21

### Added

- Benchmark filtering via `--filter` with Lua pattern matching; pass multiple `--filter` flags to
  match any pattern
- User-defined parameters via `-p name:value` (number, boolean, or string); repeatable for multiple
  values per name
- Test mode via `-t` for quick smoke testing (runs 1 round per benchmark)
- Runtime selection via `-R` to run benchmarks under a different Lua interpreter

## [0.3.0] - 2026-03-21

### Added

- JSON export via `-o results.json` including version, timestamp, targets, and results
- Progress bar showing benchmark progress with ETA, hidden automatically when output is not a
  terminal
- Benchmark results returned as structured data for use in scripts and CI

### Changed

- Benchmark section headers now use a `▌` prefix

## [0.2.0] - 2026-03-21

### Added

- Target resolution using `[alias=]repo#ref` syntax to specify repos, refs, and display names
- Support for remote URLs (HTTPS and SSH) as benchmark targets
- Local directory paths as benchmark targets (auto-detected, no `#` needed)
- Bare `.` target resolves to git repo root for benchmarking the working tree
- Alias support for display names (`v1=.#v1.0.0` shows as "v1" in output)
- Duplicate display name detection with actionable error messages
- Temp directories are always cleaned up after a run, even on failure
- Shallow clone for remote repos, full clone for local repos

### Changed

- CLI restructured: targets are now positional args, benchmark paths moved to `-b`/`--bench` flag
- Targets now display with resolved names instead of raw directory paths

### Removed

- `-r`/`--ref` flag (replaced by positional targets)

## [0.1.0] - 2026-03-20

### Added

- Benchmark file discovery with recursive directory scanning
- Single-benchmark and multi-benchmark file formats
- Target isolation — each version uses its own modules, preventing cross-version dependency leakage
- CLI entrypoint with `ref` subcommand for comparing library versions
- Support for benchmark lifecycle hooks (`before`, `after`, `baseline`)

[Unreleased]: https://github.com/jeffzi/luapit/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/jeffzi/luapit/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jeffzi/luapit/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jeffzi/luapit/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jeffzi/luapit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jeffzi/luapit/releases/tag/v0.1.0
