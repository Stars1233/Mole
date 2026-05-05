# Mole Agent Guide

## Project

Mole is a macOS system cleanup and optimization tool with shell and Go components. It performs file cleanup, app protection checks, and maintenance tasks, so safety rules matter more than speed.

## Repository Map

- `mole` - main shell entrypoint.
- `bin/` - command entry scripts such as clean, analyze, status, uninstall, purge, installer, completion, and touchid.
- `lib/core/` - shared shell safety, UI, file operations, operation logs, and app protection logic.
- `lib/clean/` - cleanup flows.
- `lib/manage/` - whitelist, update, autofix, and purge path management.
- `lib/optimize/` - optimization tasks.
- `lib/check/` - health, diagnostics, and dev environment checks.
- `lib/uninstall/` - app uninstall flows and package-manager removal helpers.
- `lib/ui/` - reusable menus and app selectors.
- `cmd/` - Go command implementations.
- `tests/` - Bats and shell test coverage.
- `scripts/` - check, test, build, and release helpers.
- `SECURITY_AUDIT.md` - security review notes.

## Commands

```bash
./scripts/check.sh --format
MOLE_TEST_NO_AUTH=1 ./scripts/test.sh
MOLE_TEST_NO_AUTH=1 bats tests/clean_core.bats
MOLE_DRY_RUN=1 ./mole clean
MOLE_TEST_NO_AUTH=1 ./mole clean --dry-run
MOLE_TEST_NO_AUTH=1 ./mole purge --dry-run
MOLE_TEST_NO_AUTH=1 ./mole installer --dry-run
find bin lib -name '*.sh' -print0 | xargs -0 -n1 bash -n
make build
go test ./...
```

Public docs and examples should prefer the installed `mo` command. Use `./mole` in this repository when verifying source-tree behavior before installation. `analyze` and `analyse` are both accepted command spellings.

## Critical Safety Rules

- Never use raw `rm -rf` or `find -delete`; use safe deletion helpers.
- Use `mole_delete` from `lib/core/file_ops.sh` for removals so Trash routing, operation logs, dry-run behavior, and path protection stay consistent.
- Never modify protected paths such as `/System`, `/Library/Apple`, or `com.apple.*`.
- Route user-facing cleanup through Trash where the project expects recoverability, especially for analyze-driven ad hoc cleanup.
- Never let verification block on sudo, AppleScript, or macOS authorization prompts unless the task explicitly targets auth behavior.
- Use `MOLE_DRY_RUN=1` before destructive cleanup flows.
- Use `MOLE_TEST_NO_AUTH=1` for tests, manual repro, and verification unless real auth behavior is being tested.
- Do not change ESC timeout behavior in `lib/core/ui.sh` unless explicitly requested.
- Preserve operation logging to the project log path unless the user explicitly asks to change `MO_NO_OPLOG` behavior.

## Working Rules

- Use helpers from `lib/core/file_ops.sh` for deletion logic.
- Check `should_protect_path()` before adding cleanup behavior.
- Check app protection helpers before adding app cache, uninstall, or leftover cleanup behavior.
- Keep AI-tool cache cleanup conservative. Claude Code, opencode, Copilot CLI, Zed, Warp, Ghostty, and similar developer tools may have active versions, config, credentials, or session state that must not be removed accidentally.
- Keep shell code formatted with `./scripts/check.sh --format`.
- Prefer targeted Bats tests during development; run the full suite before committing.
- Do not add AI attribution trailers to commits.
- `start_section` / `end_section` / `note_activity` have three intentionally different implementations in `lib/core/base.sh`, `bin/clean.sh`, and `bin/purge.sh`. Source order decides which one wins, and the wording, color, and dry-run export semantics differ on purpose. Read the cross-reference comment in `lib/core/base.sh` before changing any of them.

## Command Surface

- `mo clean` - deep cleanup and leftovers for apps that are already gone.
- `mo uninstall` - remove installed apps and related leftovers.
- `mo optimize` - maintenance and diagnostics, with `--whitelist` support.
- `mo analyze` / `mo analyse` - Go disk explorer; safer for ad hoc cleanup because it uses Trash routing.
- `mo status` - live health dashboard and JSON output for automation.
- `mo check` / `mo doctor` - run system diagnostics (updates, health, security, config, dev environment) with optional auto-fix prompts.
- `mo purge` - project build artifact cleanup, with configurable scan paths through `mo purge --paths`.
- `mo installer` - installer-file discovery and cleanup.
- `mo completion`, `mo touchid`, `mo update`, and `mo remove` manage shell integration, sudo auth convenience, updates, and uninstalling Mole itself.

## Verification

- Shell changes: run `./scripts/check.sh --format`, then the relevant Bats test or `MOLE_TEST_NO_AUTH=1 ./scripts/test.sh`.
- Go changes: run `go test ./...`.
- Cleanup behavior: verify with dry-run or test mode first.
- File operation changes: run `MOLE_TEST_NO_AUTH=1 bats tests/file_ops_mole_delete.bats tests/user_file_ops.bats`.
- Installer changes: run `MOLE_TEST_NO_AUTH=1 bats tests/installer.bats tests/installer_fd.bats tests/installer_zip.bats`.
- Purge changes: run `MOLE_TEST_NO_AUTH=1 bats tests/purge.bats tests/purge_config_paths.bats`.
- Whitelist or management changes: run `MOLE_TEST_NO_AUTH=1 bats tests/manage_whitelist.bats tests/manage_autofix.bats`.
- Uninstall changes: run `MOLE_TEST_NO_AUTH=1 bats tests/uninstall.bats tests/uninstall_remove_file_list.bats`.
- Documentation-only changes: check links and commands.

## GitHub Operations

- When closing a fixed bug or shipped feature, use project wording from the issue context and include the expected release path only when confirmed.
