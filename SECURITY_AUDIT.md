# Mole Security Audit Report

**Date:** December 12, 2025

**Audited Version:** Current `main` branch

**Status:** Passed

## Security Philosophy: "Do No Harm"

Mole is designed with a **Zero Trust** architecture regarding file operations. Every request to modify the filesystem is treated as potentially dangerous until strictly validated. Our primary directive is to prioritize system stability over aggressive cleaning—we would rather leave 1GB of junk than delete 1KB of critical user data.

## 1. Multi-Layered Defense Architecture (Automated Core)

Mole's automated shell-based operations (Clean, Optimize, Uninstall) do not execute raw commands directly. All operations pass through a hardened middleware layer (`lib/core/file_ops.sh`).

- **Layer 1: Input Sanitization**
    Before any operation reaches the execution stage, the target path is sanitized:
  - **Absolute Path Enforcement**: Relative paths (e.g., `../foo`) are strictly rejected to prevent path traversal attacks.
  - **Control Character Filtering**: Paths containing hidden control characters or newlines are blocked.
  - **Empty Variable Protection**: Guards against shell scripting errors where an empty variable could result in `rm -rf /`.

- **Layer 2: The "Iron Dome" (Path Validation)**
    A centralized validation logic explicitly blocks operations on critical system hierarchies within the shell core, even with `sudo` privileges:
  - `/` (Root)
  - `/System` and `/System/*`
  - `/bin`, `/sbin`, `/usr`, `/usr/bin`, `/usr/sbin`
  - `/etc`, `/var`
  - `/Library/Extensions`

- **Layer 3: Symlink Failsafe**
    For privileged (`sudo`) operations, Mole performs a pre-flight check to verify if the target is a **Symbolic Link**.
  - **Risk**: A malicious or accidental symlink could point from a cache folder to a system file.
  - **Defense**: Mole explicitly refuses to recursively delete symbolic links in privileged mode.

## 2. Interactive Analyzer Safety (Go Architecture)

The interactive analyzer (`mo analyze`) operates on a different security model focused on manual user control:

- **Standard User Permissions**: The tool runs with the invoking user's standard permissions. It respects macOS System Integrity Protection (SIP) and filesystem permissions.
- **Manual Confirmation**: Deletions are not automated; they require explicit user selection and confirmation.
- **OS-Level Enforcement**: Unlike the automated scripts, the analyzer relies on the operating system's built-in protections (e.g., inability to delete `/System` due to Read-Only Volume or SIP) rather than a hardcoded application-level blocklist.

## 3. Conservative Cleaning Logic

Mole's "Smart Uninstall" and orphan detection (`lib/clean/apps.sh`) are intentionally conservative:

- **Orphaned Data: The "60-Day Rule"**
    1. **Verification**: An app is confirmed "uninstalled" only if it is completely missing from `/Applications`, `~/Applications`, and `/System/Applications`.
    2. **Dormancy Check**: Associated data folders are only flagged for removal if they have not been modified for **at least 60 days**.
    3. **Vendor Whitelist**: A hardcoded whitelist protects shared resources from major vendors (Adobe, Microsoft, Google, etc.) to prevent breaking software suites.

- **Active Uninstallation Heuristics**
    When a user explicitly selects an app for uninstallation, Mole employs advanced heuristics to find scattered remnants (e.g., "Visual Studio Code" -> `~/.vscode`, `~/Library/Application Support/VisualStudioCode`).
  - **Sanitized Name Matching**: We search for app name variations to catch non-standard folder naming.
  - **Safety Constraints**: Fuzzy matching and sanitized name searches are **strictly disabled** for app names shorter than 4 characters to prevent false positives.
  - **System Scope**: Mole scans specific system-level directories (`/Library/LaunchAgents`, etc.) for related components.

- **System Integrity Protection (SIP) Awareness**
    Mole respects macOS SIP. It detects if SIP is enabled and automatically skips protected directories (like `/Library/Updates`) to avoid triggering permission errors.

- **Time Machine Preservation**
    Before cleaning failed backups, Mole checks for the `backupd` process. If a backup is currently running, the cleanup task is strictly **aborted** to prevent data corruption.

- **VPN & Proxy Protection**
    Mole includes a comprehensive protection layer for VPN and Proxy applications (e.g., Shadowsocks, V2Ray, Tailscale). It protects both their application bundles and data directories from automated cleanup to prevent network configuration loss.

## 4. Atomic Operations & Crash Safety

We anticipate that scripts can be interrupted (e.g., power loss, `Ctrl+C`).

- **Network Interface Reset**: Wi-Fi and AirDrop resets use **atomic execution blocks**.
- **Swap Clearing**: Swap files are reset by securely restarting the `dynamic_pager` daemon. We intentionally avoid manual `rm` operations on swap files to prevent instability during high memory pressure.

## 5. User Control & Transparency

- **Dry-Run Mode (`--dry-run`)**: Simulates the entire cleanup process, listing every single file and byte that *would* be removed, without touching the disk.
- **Custom Whitelists**: Users can define their own immutable paths in `~/.config/mole/whitelist`.

## 6. Dependency Audit

- **System Binaries (Shell Core)**
    Mole relies on standard, battle-tested macOS binaries for critical tasks:
  - `plutil`: Used to validate `.plist` integrity.
  - `tmutil`: Used for safe interaction with Time Machine.
  - `dscacheutil`: Used for system-compliant cache rebuilding.

- **Go Dependencies (Interactive Tools)**
    The compiled Go binary (`analyze-go`) includes the following libraries:
  - `bubbletea` & `lipgloss`: UI framework (Charm).
  - `gopsutil`: System metrics collection.
  - `xxhash`: Efficient hashing.

*This document certifies that Mole's architecture implements industry-standard defensive programming practices to ensure the safety and integrity of your Mac.*
