# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-03-20

### Added

- Benchmark file discovery with recursive directory scanning
- Benchmark loader with single-Spec and named-Specs format detection
- Runner with target isolation via package.path/package.loaded snapshots
- CLI entrypoint with `ref` subcommand for comparing library versions
- Full support for luamark Spec hooks (before, after, baseline)

### Changed

- Restructured project from flat module to submodule layout

[Unreleased]: https://github.com/jeffzi/luabench/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jeffzi/luabench/releases/tag/v0.2.0
