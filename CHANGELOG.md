# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--lua-path` option to add subdirectories within each target to
  `package.path` (repeatable), for projects where Lua files live under
  a subdirectory (e.g., `--lua-path lua`)
- `--prepare` hook to run a shell command in each cloned target directory
  before benchmarking (e.g., compile TypeScript-to-Lua or Fennel sources)
- Love2D runtime (`-R love`): runs benchmarks in a headless Love2D
  project for code that depends on Love2D APIs
- Defold runtime (`-R defold`): builds a minimal Defold project and
  runs benchmarks via the headless engine
- Defold HTML5 runtime (`-R defold-html5`): builds for the `js-web`
  platform and runs benchmarks in headless Chromium via Playwright

### Fixed

- Ctrl-C during a benchmark run now exits immediately instead of being
  swallowed as a warning

## [0.4.0] - 2026-03-21

### Added

- Benchmark filtering via `--filter` with Lua pattern matching and OR logic for multiple patterns
- User-defined parameters via `-p name:value` with auto-coercion
  (number, boolean, string), repeatable for multiple values per name
- Test mode via `-t` for quick smoke testing (runs 1 round per benchmark)
- Runtime selection via `-R` to spawn benchmarks under a different Lua interpreter

## [0.3.0] - 2026-03-21

### Added

- JSON export via `-o results.json` with metadata envelope (version, timestamp, targets, results)
- Progress bar showing benchmark progress with ETA, auto-disabled on non-TTY
- Benchmark results available as structured data for programmatic use

### Changed

- Benchmark headers use `▌` prefix instead of dashes

## [0.2.0] - 2026-03-21

### Added

- Target resolution with git refspec parsing (`[alias=]repo#ref` format)
- Support for remote URLs (HTTPS and SSH) as benchmark targets
- Local directory paths as benchmark targets (auto-detected, no `#` needed)
- Bare `.` target resolves to git repo root for benchmarking the working tree
- Alias support for display names (`v1=.#v1.0.0` shows as "v1" in output)
- Duplicate display name detection with actionable error messages
- Temp directory lifecycle management with guaranteed cleanup
- Shallow clone for remote repos, full clone for local repos

### Changed

- CLI restructured: targets are now positional args, benchmark paths moved to `-b`/`--bench` flag
- Targets now display with resolved names instead of raw directory paths

### Removed

- `-r`/`--ref` flag (replaced by positional targets)

## [0.1.0] - 2026-03-20

### Added

- Benchmark file discovery with recursive directory scanning
- Single-spec and named-specs benchmark file formats
- Target isolation — each version uses its own modules, preventing cross-version leakage
- CLI entrypoint with `ref` subcommand for comparing library versions
- Full support for luamark Spec hooks (before, after, baseline)

### Changed

- Restructured project from flat module to submodule layout

[Unreleased]: https://github.com/jeffzi/luabench/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/jeffzi/luabench/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jeffzi/luabench/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jeffzi/luabench/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jeffzi/luabench/releases/tag/v0.1.0
