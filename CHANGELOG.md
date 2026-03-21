# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Runner accepts structured `{path, name}` targets instead of plain directory strings

### Removed

- `-r`/`--ref` flag (replaced by positional targets)

## [0.1.0] - 2026-03-20

### Added

- Benchmark file discovery with recursive directory scanning
- Benchmark loader with single-Spec and named-Specs format detection
- Runner with target isolation via package.path/package.loaded snapshots
- CLI entrypoint with `ref` subcommand for comparing library versions
- Full support for luamark Spec hooks (before, after, baseline)

### Changed

- Restructured project from flat module to submodule layout

[Unreleased]: https://github.com/jeffzi/luabench/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jeffzi/luabench/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jeffzi/luabench/releases/tag/v0.1.0
