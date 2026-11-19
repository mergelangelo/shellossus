# Changelog

All notable changes to `shellossus` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Retry-After` header support (delta seconds and HTTP-date) with up to 3 transient HTTP retries and exponential backoff + jitter in `Invoke-AgentTurn` and the isolated `http` worker.

## [0.9.0] - 2026-11-19

### Added
- Standalone `-Version` launch switch (`text` and `-Mode json`), `version` metadata in `-Doctor` reports, and version display in the interactive TUI startup banner.
- `SHELLOSSUS_SEARCH_URL` configuration file (`.env`) support, `{query}` URL placeholder expansion, and JSON search response auto-detection (`results`, `web.results`, `items`, `data`, and top-level arrays) in `web_search`.
- Stale session `.lock` recovery: `.lock` files record writer PID, process start ticks, host, and UTC timestamp; stale locks from terminated processes, reused PIDs, or aged unreadable/foreign locks are safely reclaimed via atomic rename without touching active locks, directories, or reparse points.
- Optional SSE response assembly (`-Stream` / `SHELLOSSUS_STREAM`) with fail-closed `[DONE]` and `finish_reason` verification across turns, compaction, and subagents.
- Configurable model request timeout (`-RequestTimeoutSec` / `SHELLOSSUS_REQUEST_TIMEOUT_SEC`).
- Turn-scoped workspace walk cache and literal prefiltering in `grep_files`.

### Changed
- Updated `write_file` and `edit_file` tool schema path descriptions to accurately reflect automatic parent directory creation for `write_file` and existing-file requirement for `edit_file`.
- Hardened internal workers (`http`, `web`, `subagent`) to invoke `shellossus.ps1` via `-File -InternalWorker` instead of `-EncodedCommand`, with cold-start `ConstrainedLanguage` verification in CI across Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
