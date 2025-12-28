#!/bin/bash
# Mole - File Operations
# Safe file and directory manipulation with validation

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_FILE_OPS_LOADED=1

# Ensure dependencies are loaded
_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
if [[ -z "${MOLE_LOG_LOADED:-}" ]]; then
    # shellcheck source=lib/core/log.sh
    source "$_MOLE_CORE_DIR/log.sh"
fi
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi

# ============================================================================
# Path Validation
# ============================================================================

# Validate path for deletion (absolute, no traversal, not system dir)
validate_path_for_deletion() {
    local path="$1"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    if [[ "$path" =~ \.\. ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    # Check path isn't critical system directory
    case "$path" in
        / | /bin | /sbin | /usr | /usr/bin | /usr/sbin | /etc | /var | /System | /System/* | /Library/Extensions)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
    esac

    return 0
}

# ============================================================================
# Safe Removal Operations
# ============================================================================

# Safe wrapper around rm -rf with validation
safe_remove() {
    local path="$1"
    local silent="${2:-false}"

    # Validate path
    if ! validate_path_for_deletion "$path"; then
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    debug_log "Removing: $path"

    # Perform the deletion
    if rm -rf "$path" 2> /dev/null; then # SAFE: safe_remove implementation
        return 0
    else
        [[ "$silent" != "true" ]] && log_error "Failed to remove: $path"
        return 1
    fi
}

# Safe sudo removal with symlink protection
safe_sudo_remove() {
    local path="$1"

    # Validate path
    if ! validate_path_for_deletion "$path"; then
        log_error "Path validation failed for sudo remove: $path"
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Additional check: reject symlinks for sudo operations
    if [[ -L "$path" ]]; then
        log_error "Refusing to sudo remove symlink: $path"
        return 1
    fi

    debug_log "Removing (sudo): $path"

    # Perform the deletion
    if sudo rm -rf "$path" 2> /dev/null; then # SAFE: safe_sudo_remove implementation
        return 0
    else
        log_error "Failed to remove (sudo): $path"
        return 1
    fi
}

# ============================================================================
# Safe Find and Delete Operations
# ============================================================================

# Safe file discovery and deletion with depth and age limits
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter (must be 'f' or 'd')"
        return 1
    fi

    debug_log "Finding in $base_dir: $pattern (age: ${age_days}d, type: $type_filter)"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect should_protect_path when available
    while IFS= read -r -d '' match; do
        if command -v should_protect_path > /dev/null 2>&1; then
            if should_protect_path "$match"; then
                continue
            fi
        fi
        safe_remove "$match" true || true
    done < <(command find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# Safe sudo discovery and deletion
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory (use sudo for permission-restricted dirs)
    if ! sudo test -d "$base_dir" 2> /dev/null; then
        debug_log "Directory does not exist (skipping): $base_dir"
        return 0
    fi

    if sudo test -L "$base_dir" 2> /dev/null; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter (must be 'f' or 'd')"
        return 1
    fi

    debug_log "Finding (sudo) in $base_dir: $pattern (age: ${age_days}d, type: $type_filter)"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect should_protect_path when available
    while IFS= read -r -d '' match; do
        if command -v should_protect_path > /dev/null 2>&1; then
            if should_protect_path "$match"; then
                continue
            fi
        fi
        safe_sudo_remove "$match" || true
    done < <(sudo find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# ============================================================================
# Size Calculation
# ============================================================================

# Get path size in KB (returns 0 if not found)
get_path_size_kb() {
    local path="$1"
    [[ -z "$path" || ! -e "$path" ]] && {
        echo "0"
        return
    }
    # Direct execution without timeout overhead - critical for performance in loops
    local size
    size=$(command du -sk "$path" 2> /dev/null | awk '{print $1}')
    echo "${size:-0}"
}

# Calculate total size for multiple paths
calculate_total_size() {
    local files="$1"
    local total_kb=0

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "$file")
            ((total_kb += size_kb))
        fi
    done <<< "$files"

    echo "$total_kb"
}
