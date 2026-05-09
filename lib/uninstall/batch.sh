#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Load Homebrew cask support (provides get_brew_cask_name, brew_uninstall_cask)
[[ -f "$SCRIPT_DIR/lib/uninstall/brew.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/brew.sh"

# Batch uninstall with a single confirmation.

is_uninstall_dry_run() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]]
}

app_declares_local_network_usage() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"

    [[ -f "$info_plist" ]] || return 1

    if plutil -extract NSLocalNetworkUsageDescription raw "$info_plist" > /dev/null 2>&1; then
        return 0
    fi

    if plutil -extract NSBonjourServices xml1 -o - "$info_plist" > /dev/null 2>&1; then
        return 0
    fi

    return 1
}

# High-performance sensitive data detection (pure Bash, no subprocess)
# Faster than grep for batch operations, especially when processing many apps
has_sensitive_data() {
    local files="$1"
    [[ -z "$files" ]] && return 1

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Use Bash native pattern matching (faster than spawning grep)
        case "$file" in
            */.warp* | */.config/* | */themes/* | */settings/* | */User\ Data/* | \
                */.ssh/* | */.gnupg/* | */Documents/* | */Preferences/*.plist | \
                */Desktop/* | */Downloads/* | */Movies/* | */Music/* | */Pictures/* | \
                */.password* | */.token* | */.auth* | */keychain* | \
                */Passwords/* | */Accounts/* | */Cookies/* | \
                */.aws/* | */.docker/config.json | */.kube/* | \
                */credentials/* | */secrets/*)
                return 0 # Found sensitive data
                ;;
        esac
    done <<< "$files"

    return 1 # Not found
}

# Decode and validate base64 file list (safe for set -e).
decode_file_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode file list for $app_name" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "File list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0 # Return success with empty string
    fi

    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^/ ]]; then
            log_warning "Invalid path in file list for $app_name: $line" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    done <<< "$decoded"

    echo "$decoded"
    return 0
}
# Note: find_app_files() and calculate_total_size() are in lib/core/common.sh.

# Unload Launch Agents/Daemons for an app. **Unload only** -- never remove the
# plist file. Plist deletion is owned by `remove_file_list` so the review
# picker's selection is the single source of truth for what survives on disk.
# Always called before file removal so we don't strand a running daemon when
# its plist is about to be deleted.
# Security: bundle_id is validated to be reverse-DNS format before use in find patterns
stop_launch_services() {
    local bundle_id="$1"
    local has_system_files="${2:-false}"
    local app_path="${3:-}"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would unload launch services for bundle: $bundle_id"
        return 0
    fi

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    # Validate bundle_id format: must be reverse-DNS style (e.g., com.example.app)
    # This prevents glob injection attacks if bundle_id contains special characters
    if [[ ! "$bundle_id" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        debug_log "Invalid bundle_id format for LaunchAgent search: $bundle_id"
        return 0
    fi

    if [[ -d ~/Library/LaunchAgents ]]; then
        while IFS= read -r -d '' plist; do
            launchctl unload "$plist" 2> /dev/null || true
        done < <(find ~/Library/LaunchAgents -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
    fi

    if [[ "$has_system_files" == "true" ]]; then
        if [[ -d /Library/LaunchAgents ]]; then
            while IFS= read -r -d '' plist; do
                sudo launchctl unload "$plist" 2> /dev/null || true
            done < <(find /Library/LaunchAgents -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
        fi
        if [[ -d /Library/LaunchDaemons ]]; then
            while IFS= read -r -d '' plist; do
                sudo launchctl unload "$plist" 2> /dev/null || true
            done < <(find /Library/LaunchDaemons -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
        fi
    fi

    # Scan for LaunchAgents whose ProgramArguments reference the app path.
    # Catches agents with bundle IDs that don't match the app's bundle ID.
    if [[ -n "$app_path" ]]; then
        if [[ -d ~/Library/LaunchAgents ]]; then
            while IFS= read -r -d '' plist; do
                launchctl unload "$plist" 2> /dev/null || true
            done < <(grep -rlZ "$app_path" ~/Library/LaunchAgents/ 2> /dev/null || true)
        fi
        if [[ "$has_system_files" == "true" ]]; then
            if [[ -d /Library/LaunchAgents ]]; then
                while IFS= read -r -d '' plist; do
                    sudo launchctl unload "$plist" 2> /dev/null || true
                done < <(grep -rlZ "$app_path" /Library/LaunchAgents/ 2> /dev/null || true)
            fi
            if [[ -d /Library/LaunchDaemons ]]; then
                while IFS= read -r -d '' plist; do
                    sudo launchctl unload "$plist" 2> /dev/null || true
                done < <(grep -rlZ "$app_path" /Library/LaunchDaemons/ 2> /dev/null || true)
            fi
        fi
    fi
}

# Unregister app bundle from LaunchServices before deleting files.
# This helps remove stale app entries from Spotlight's app results list.
unregister_app_bundle() {
    local app_path="$1"

    [[ -n "$app_path" && -e "$app_path" ]] || return 0
    [[ "$app_path" == *.app ]] || return 0

    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    set +e
    "$lsregister" -u "$app_path" > /dev/null 2>&1
    set -e
}

# Compact and rebuild LaunchServices after uninstall batch to clear stale app metadata.
refresh_launch_services_after_uninstall() {
    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    local success=0
    set +e
    # Add 10s timeout to prevent hanging (gc is usually fast)
    # run_with_timeout falls back to shell implementation if timeout command unavailable
    run_with_timeout 10 "$lsregister" -gc > /dev/null 2>&1 || true
    # Add 15s timeout for rebuild (can be slow on some systems)
    run_with_timeout 15 "$lsregister" -r -f -domain local -domain user -domain system > /dev/null 2>&1
    success=$?
    # 124 = timeout exit code (from run_with_timeout or timeout command)
    if [[ $success -eq 124 ]]; then
        debug_log "LaunchServices rebuild timed out, trying lighter version"
        run_with_timeout 10 "$lsregister" -r -f -domain local -domain user > /dev/null 2>&1
        success=$?
    elif [[ $success -ne 0 ]]; then
        run_with_timeout 10 "$lsregister" -r -f -domain local -domain user > /dev/null 2>&1
        success=$?
    fi
    set -e

    [[ $success -eq 0 || $success -eq 124 ]]
}

# Remove macOS Login Items for an app
remove_login_item() {
    local app_name="$1"
    local bundle_id="$2"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would remove login item: ${app_name:-$bundle_id}"
        return 0
    fi

    # Skip if no identifiers provided
    [[ -z "$app_name" && -z "$bundle_id" ]] && return 0

    # Strip .app suffix if present (login items don't include it)
    local clean_name="${app_name%.app}"

    # Remove from Login Items using index-based deletion (handles broken items)
    if [[ -n "$clean_name" ]]; then
        # Skip AppleScript during tests to avoid permission dialogs
        if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            # Escape double quotes and backslashes for AppleScript
            local escaped_name="${clean_name//\\/\\\\}"
            escaped_name="${escaped_name//\"/\\\"}"

            osascript <<- EOF > /dev/null 2>&1 || true
				tell application "System Events"
				    try
				        set itemCount to count of login items
				        -- Delete in reverse order to avoid index shifting
				        repeat with i from itemCount to 1 by -1
				            try
				                set itemName to name of login item i
				                if itemName is "$escaped_name" then
				                    delete login item i
				                end if
				            end try
				        end repeat
				    end try
				end tell
			EOF
        fi
    fi
}

# Remove files (handles symlinks, optional sudo).
# Security: All paths pass validate_path_for_deletion() before any deletion.
# Performance: when MOLE_DELETE_MODE=trash and the batch is sudo-free and
# symlink-free, the eligible paths are sent to Trash in a single subprocess
# (one `trash` exec or one Finder AppleScript round-trip). This collapses the
# previous N-subprocess fan-out that caused the post-confirmation "frozen
# terminal" reported during `mo uninstall` on apps with many leftovers.
remove_file_list() {
    local file_list="$1"
    local use_sudo="${2:-false}"
    local count=0
    local mode="${MOLE_DELETE_MODE:-permanent}"

    local -a trash_batch=()
    local -a fallback_paths=()

    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] || continue

        if ! validate_path_for_deletion "$file"; then
            continue
        fi

        if [[ "$use_sudo" == "true" ]] && is_uninstall_dry_run; then
            debug_log "[DRY RUN] Would sudo remove: $file"
            ((++count))
            continue
        fi

        # Symlinks and sudo-required paths stay on the per-file mole_delete
        # path: safe_remove_symlink semantics differ from Trash, and AppleScript
        # cannot run reliably as root for the batch fallback.
        if [[ "$mode" == "trash" && "$use_sudo" != "true" && ! -L "$file" ]] &&
            ! is_uninstall_dry_run; then
            trash_batch+=("$file")
        else
            fallback_paths+=("$file")
        fi
    done <<< "$file_list"

    if [[ ${#trash_batch[@]} -gt 0 ]]; then
        if _mole_move_to_trash_batch "${trash_batch[@]}"; then
            local _bp _bsize
            for _bp in "${trash_batch[@]}"; do
                _bsize="unknown"
                _mole_delete_log "trash" "$_bsize" "ok" "$_bp"
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$_bp" "batch"
            done
            count=$((count + ${#trash_batch[@]}))
        else
            # Batch failed wholesale: route each path through mole_delete so
            # the per-file fallback (Trash retry, then permanent rm) runs and
            # forensic logging stays intact.
            fallback_paths+=("${trash_batch[@]}")
        fi
    fi

    if [[ ${#fallback_paths[@]} -gt 0 ]]; then
        local fb
        for fb in "${fallback_paths[@]}"; do
            # mole_delete routes through Trash when MOLE_DELETE_MODE=trash
            # (uninstall default), falls back to the underlying safe_* helpers
            # in permanent mode or when Trash is unavailable. See #723.
            mole_delete "$fb" "$use_sudo" && ((++count)) || true
        done
    fi

    echo "$count"
}

# Interactive review picker.
#
# Reads the caller's `app_details` array (12-column rows from
# `batch_uninstall_applications`), flattens each app's removal candidates
# (the `.app` bundle plus user/system/diagnostic file buckets) into a flat
# multi-select catalogue with everything preselected, runs
# `paginated_multi_select`, then rebuilds `app_details` so that:
#   - `related_files`, `system_files`, and `diag_system` retain only the
#     paths the user kept selected (re-base64-encoded in place);
#   - a 13th column `keep_app` (`true|false`) is appended. `keep_app=true`
#     means the user explicitly deselected the `.app` row -- callers must
#     skip the bundle-removal / launch-services / brew-cask steps for that
#     entry but may still drop the surviving leftover files.
#
# Returns 0 on confirm (mutates `app_details` in place via dynamic scope),
# returns 1 on picker cancel (`app_details` is left untouched).
interactive_review_files() {
    [[ ${#app_details[@]} -eq 0 ]] && return 0

    local -a row_app_idx=()
    local -a row_bucket=()
    local -a row_path=()
    local -a menu_options=()

    local app_idx=0
    local detail
    for detail in "${app_details[@]}"; do
        local app_name app_path bundle_id total_kb encoded_files encoded_system_files
        local has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system has_local_network_usage
        local _existing_keep_app="false"
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files \
            has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system has_local_network_usage \
            _existing_keep_app <<< "$detail"

        # .app bundle row.
        row_app_idx+=("$app_idx")
        row_bucket+=("app")
        row_path+=("$app_path")
        menu_options+=("$(_review_format_menu_row "$app_name" "$app_path" "false")")

        # Related user files.
        local related_files
        related_files=$(decode_file_list "$encoded_files" "$app_name")
        local f
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            row_app_idx+=("$app_idx")
            row_bucket+=("related")
            row_path+=("$f")
            menu_options+=("$(_review_format_menu_row "$app_name" "$f" "false")")
        done <<< "$related_files"

        # System files (sudo-required).
        local system_files
        system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            row_app_idx+=("$app_idx")
            row_bucket+=("system")
            row_path+=("$f")
            menu_options+=("$(_review_format_menu_row "$app_name" "$f" "true")")
        done <<< "$system_files"

        # System-level diagnostic reports.
        local diag_system
        diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            row_app_idx+=("$app_idx")
            row_bucket+=("diag")
            row_path+=("$f")
            menu_options+=("$(_review_format_menu_row "$app_name" "$f" "true")")
        done <<< "$diag_system"

        app_idx=$((app_idx + 1))
    done

    local total_rows=${#menu_options[@]}
    [[ $total_rows -eq 0 ]] && return 0

    # Preselect every row -- the picker's job is to let the user opt OUT of paths.
    local preselect_csv=""
    local i
    for ((i = 0; i < total_rows; i++)); do
        if [[ -z "$preselect_csv" ]]; then
            preselect_csv="$i"
        else
            preselect_csv+=",$i"
        fi
    done
    export MOLE_PRESELECTED_INDICES="$preselect_csv"

    MOLE_SELECTION_RESULT=""
    local exit_code=0
    paginated_multi_select "Review files to remove" "${menu_options[@]}" || exit_code=$?
    unset MOLE_PRESELECTED_INDICES

    if [[ $exit_code -ne 0 ]]; then
        return 1
    fi

    # Map surviving (still-selected) row indices into a per-row boolean.
    local -a row_kept=()
    for ((i = 0; i < total_rows; i++)); do
        row_kept[i]="false"
    done
    if [[ -n "$MOLE_SELECTION_RESULT" ]]; then
        local idx
        local -a indices_array=()
        IFS=',' read -r -a indices_array <<< "$MOLE_SELECTION_RESULT"
        for idx in "${indices_array[@]}"; do
            if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -ge 0 ]] && [[ $idx -lt $total_rows ]]; then
                row_kept[idx]="true"
            fi
        done
    fi

    # Rebuild each app_details row from the surviving paths.
    local -a new_app_details=()
    local current_app=0
    while [[ $current_app -lt ${#app_details[@]} ]]; do
        local detail_in="${app_details[current_app]}"
        local app_name app_path bundle_id total_kb encoded_files encoded_system_files
        local has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system has_local_network_usage
        local _ignored_keep_app="false"
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files \
            has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system has_local_network_usage \
            _ignored_keep_app <<< "$detail_in"

        local keep_app="false"
        local -a kept_related=()
        local -a kept_system=()
        local -a kept_diag=()

        for ((i = 0; i < total_rows; i++)); do
            [[ "${row_app_idx[i]}" != "$current_app" ]] && continue
            local bucket="${row_bucket[i]}"
            local p="${row_path[i]}"
            local sel="${row_kept[i]}"
            case "$bucket" in
                app)
                    # `.app` row preselected = remove. Deselected = keep the bundle.
                    [[ "$sel" == "false" ]] && keep_app="true"
                    ;;
                related)
                    [[ "$sel" == "true" ]] && kept_related+=("$p")
                    ;;
                system)
                    [[ "$sel" == "true" ]] && kept_system+=("$p")
                    ;;
                diag)
                    [[ "$sel" == "true" ]] && kept_diag+=("$p")
                    ;;
            esac
        done

        local new_related="" new_system="" new_diag=""
        [[ ${#kept_related[@]} -gt 0 ]] && new_related=$(printf '%s\n' "${kept_related[@]}")
        [[ ${#kept_system[@]} -gt 0 ]] && new_system=$(printf '%s\n' "${kept_system[@]}")
        [[ ${#kept_diag[@]} -gt 0 ]] && new_diag=$(printf '%s\n' "${kept_diag[@]}")

        local enc_related enc_system enc_diag
        enc_related=$(printf '%s' "$new_related" | base64 | tr -d '\n')
        enc_system=$(printf '%s' "$new_system" | base64 | tr -d '\n')
        enc_diag=$(printf '%s' "$new_diag" | base64 | tr -d '\n')

        # Recompute total_kb so the re-rendered confirm prompt reflects the
        # trimmed selection rather than the pre-review snapshot.
        local new_total_kb=0
        if [[ "$keep_app" != "true" ]]; then
            new_total_kb=$((new_total_kb + $(get_path_size_kb "$app_path" 2> /dev/null || echo 0)))
        fi
        [[ -n "$new_related" ]] && new_total_kb=$((new_total_kb + $(calculate_total_size "$new_related" 2> /dev/null || echo 0)))
        [[ -n "$new_system" ]] && new_total_kb=$((new_total_kb + $(calculate_total_size "$new_system" 2> /dev/null || echo 0)))
        [[ -n "$new_diag" ]] && new_total_kb=$((new_total_kb + $(calculate_total_size "$new_diag" 2> /dev/null || echo 0)))

        new_app_details+=("$app_name|$app_path|$bundle_id|$new_total_kb|$enc_related|$enc_system|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$enc_diag|$has_local_network_usage|$keep_app")
        current_app=$((current_app + 1))
    done

    app_details=("${new_app_details[@]}")
    return 0
}

# Format one row in the review picker. Adds a `[system]` tag for sudo-required
# paths so they are visually distinguished when scanning the list.
_review_format_menu_row() {
    local app_name="$1" path="$2" is_system="$3"
    local display="${path/#$HOME/~}"
    local tag=""
    if [[ "$is_system" == "true" ]]; then
        tag="  ${GRAY:-}[system]${NC:-}"
    fi
    printf "%s: %s%s" "$app_name" "$display" "$tag"
}

# Render the "Files to be removed:" preview block for the current
# `app_details` snapshot. Reads `app_details` and `brew_cask_apps` via
# dynamic scope so it can be re-rendered after `interactive_review_files`
# mutates them.
_print_files_to_remove() {
    echo -e "\n${PURPLE_BOLD}Files to be removed:${NC}"

    local has_brew_cask=false
    [[ ${#brew_cask_apps[@]} -gt 0 ]] && has_brew_cask=true
    if [[ "$has_brew_cask" == "true" ]]; then
        echo -e "${GRAY}${ICON_WARNING} Homebrew apps will be fully cleaned, --zap removes configs and data${NC}"
    fi
    echo ""

    local detail
    for detail in "${app_details[@]}"; do
        local app_name app_path bundle_id total_kb encoded_files encoded_system_files
        local has_sensitive_data needs_sudo_flag is_brew_cask cask_name encoded_diag_system
        local has_local_network_usage keep_app="false"
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files \
            has_sensitive_data needs_sudo_flag is_brew_cask cask_name encoded_diag_system \
            has_local_network_usage keep_app <<< "$detail"
        local app_size_display=$(bytes_to_human "$((total_kb * 1024))")

        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        local kept_tag=""
        [[ "$keep_app" == "true" ]] && kept_tag=" ${YELLOW}[kept]${NC}"
        echo -e "${BLUE}${ICON_CONFIRM}${NC} ${app_name}${brew_tag}${kept_tag} ${GRAY}, ${app_size_display}${NC}"

        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system_display
        diag_system_display=$(decode_file_list "$encoded_diag_system" "$app_name")
        [[ -n "$diag_system_display" ]] && system_files=$(
            [[ -n "$system_files" ]] && echo "$system_files"
            echo "$diag_system_display"
        )

        if [[ "$keep_app" != "true" ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${app_path/$HOME/~}"
        fi

        local file
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${file/$HOME/~}"
            fi
        done <<< "$related_files"

        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                echo -e "  ${BLUE}${ICON_WARNING}${NC} System: $file"
            fi
        done <<< "$system_files"
    done
}

# Recompute the sudo / brew_cask aggregates after a file review pass so the
# downstream sudo gate and brew autoremove logic see the current state.
# `keep_app=true` apps no longer trigger their own sudo or brew uninstall;
# system file lists may have shrunk to empty.
_recompute_uninstall_aggregates() {
    sudo_apps=()
    brew_cask_apps=()
    total_estimated_size=0

    local detail
    for detail in "${app_details[@]}"; do
        local app_name app_path bundle_id total_kb encoded_files encoded_system_files
        local has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system
        local has_local_network_usage keep_app="false"
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files \
            has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system \
            has_local_network_usage keep_app <<< "$detail"

        local has_system_remaining="false"
        if [[ -n "$encoded_system_files" || -n "$encoded_diag_system" ]]; then
            has_system_remaining="true"
        fi

        local needs_sudo_now="false"
        if [[ "$has_system_remaining" == "true" ]]; then
            needs_sudo_now="true"
        elif [[ "$keep_app" != "true" && "$needs_sudo" == "true" ]]; then
            # We will still try to delete the .app bundle, which originally
            # required sudo (parent dir or owner mismatch).
            needs_sudo_now="true"
        fi

        if [[ "$needs_sudo_now" == "true" ]]; then
            sudo_apps+=("$app_name")
        fi
        if [[ "$is_brew_cask" == "true" && "$keep_app" != "true" ]]; then
            brew_cask_apps+=("$app_name")
        fi

        if [[ "$total_kb" =~ ^[0-9]+$ ]]; then
            total_estimated_size=$((total_estimated_size + total_kb))
        fi
    done

    if declare -p size_display > /dev/null 2>&1; then
        size_display=$(bytes_to_human "$((total_estimated_size * 1024))")
    fi
}

# Batch uninstall with single confirmation.
batch_uninstall_applications() {
    local total_size_freed=0

    # shellcheck disable=SC2154
    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    local old_trap_int old_trap_term
    old_trap_int=$(trap -p INT)
    old_trap_term=$(trap -p TERM)

    _cleanup_sudo_keepalive() {
        if command -v stop_sudo_session > /dev/null 2>&1; then
            stop_sudo_session
        fi
    }

    _restore_uninstall_traps() {
        _cleanup_sudo_keepalive
        if [[ -n "$old_trap_int" ]]; then
            eval "$old_trap_int"
        else
            trap - INT
        fi
        if [[ -n "$old_trap_term" ]]; then
            eval "$old_trap_term"
        else
            trap - TERM
        fi
    }

    # Trap to clean up spinner, sudo keepalive, and uninstall mode on interrupt
    trap 'stop_inline_spinner 2>/dev/null; _cleanup_sudo_keepalive; unset MOLE_UNINSTALL_MODE; echo ""; _restore_uninstall_traps; return 130' INT TERM

    # Pre-scan: running apps, sudo needs, size.
    local -a running_apps=()
    local -a sudo_apps=()
    local -a brew_cask_apps=()
    local total_estimated_size=0
    local -a app_details=()

    # Cache current user outside loop
    local current_user=$(whoami)

    if [[ -t 1 ]]; then start_inline_spinner "Scanning files..."; fi
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r _ app_path app_name bundle_id _ _ <<< "$selected_app"

        # Check running app by bundle executable if available
        local exec_name=""
        local info_plist="$app_path/Contents/Info.plist"
        if [[ -e "$info_plist" ]]; then
            exec_name=$(plutil -extract CFBundleExecutable raw "$info_plist" 2> /dev/null || echo "")
        fi
        if pgrep -qx "${exec_name:-$app_name}" 2> /dev/null; then
            running_apps+=("$app_name")
        fi

        local cask_name="" is_brew_cask="false"
        local resolved_path=$(readlink "$app_path" 2> /dev/null || echo "")
        if [[ "$resolved_path" == */Caskroom/* ]]; then
            # Extract cask name using bash parameter expansion (faster than sed)
            local tmp="${resolved_path#*/Caskroom/}"
            cask_name="${tmp%%/*}"
            [[ -n "$cask_name" ]] && is_brew_cask="true"
        elif command -v get_brew_cask_name > /dev/null 2>&1; then
            local detected_cask
            detected_cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
            if [[ -n "$detected_cask" ]]; then
                cask_name="$detected_cask"
                is_brew_cask="true"
            fi
        fi

        if [[ "$is_brew_cask" == "true" ]]; then
            brew_cask_apps+=("$app_name")
        fi

        # Check if sudo is needed
        local needs_sudo=false
        local app_owner=$(get_file_owner "$app_path")
        if [[ ! -w "$(dirname "$app_path")" ]] ||
            [[ "$app_owner" == "root" ]] ||
            [[ -n "$app_owner" && "$app_owner" != "$current_user" ]]; then
            needs_sudo=true
        fi

        local app_size_kb=$(get_path_size_kb "$app_path" || echo "0")
        local related_files=$(find_app_files "$bundle_id" "$app_name" || true)
        local diag_user
        diag_user=$(get_diagnostic_report_paths_for_app "$app_path" "$app_name" "$HOME/Library/Logs/DiagnosticReports" || true)
        [[ -n "$diag_user" ]] && related_files=$(
            [[ -n "$related_files" ]] && echo "$related_files"
            echo "$diag_user"
        )
        local related_size_kb=$(calculate_total_size "$related_files" || echo "0")
        # system_files is a newline-separated string, not an array.
        # shellcheck disable=SC2178,SC2128
        local system_files=$(find_app_system_files "$bundle_id" "$app_name" || true)
        local diag_system
        diag_system=$(get_diagnostic_report_paths_for_app "$app_path" "$app_name" "/Library/Logs/DiagnosticReports" || true)
        # shellcheck disable=SC2128
        local system_size_kb=$(calculate_total_size "$system_files" || echo "0")
        local diag_system_size_kb=$(calculate_total_size "$diag_system" || echo "0")
        local total_kb=$((app_size_kb + related_size_kb + system_size_kb + diag_system_size_kb))
        total_estimated_size=$((total_estimated_size + total_kb))

        # shellcheck disable=SC2128
        if [[ -n "$system_files" || -n "$diag_system" ]]; then
            needs_sudo=true
        fi

        if [[ "$needs_sudo" == "true" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Check for sensitive user data once.
        local has_sensitive_data="false"
        if has_sensitive_data "$related_files" 2> /dev/null; then
            has_sensitive_data="true"
        fi

        local has_local_network_usage="false"
        if app_declares_local_network_usage "$app_path"; then
            has_local_network_usage="true"
        fi

        # Store details for later use (base64 keeps lists on one line).
        local encoded_files
        encoded_files=$(printf '%s' "$related_files" | base64 | tr -d '\n' || echo "")
        local encoded_system_files
        encoded_system_files=$(printf '%s' "$system_files" | base64 | tr -d '\n' || echo "")
        local encoded_diag_system
        encoded_diag_system=$(printf '%s' "$diag_system" | base64 | tr -d '\n' || echo "")
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system|$has_local_network_usage|false")
    done
    if [[ -t 1 ]]; then stop_inline_spinner; fi

    local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

    _print_files_to_remove

    # Confirmation before requesting sudo.
    local app_total=${#selected_apps[@]}
    local app_text="app"
    [[ $app_total -gt 1 ]] && app_text="apps"

    local removal_note=""
    _build_removal_note() {
        removal_note="Remove ${app_total} ${app_text}"
        [[ -n "$size_display" ]] && removal_note+=", ${size_display}"
        if [[ ${#running_apps[@]} -gt 0 ]]; then
            removal_note+=" ${YELLOW}[Running]${NC}"
        fi
    }

    _build_removal_note
    echo ""
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${YELLOW}R${NC} review, ${GRAY}ESC${NC} cancel: "

    while true; do
        drain_pending_input # Clean up any pending input before confirmation
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants
        case "$key" in
            $'\e' | q | Q)
                echo ""
                echo ""
                _restore_uninstall_traps
                return 0
                ;;
            r | R)
                echo ""
                if interactive_review_files; then
                    _recompute_uninstall_aggregates
                    _print_files_to_remove
                    _build_removal_note
                fi
                echo ""
                echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${YELLOW}R${NC} review, ${GRAY}ESC${NC} cancel: "
                continue
                ;;
            "" | $'\n' | $'\r' | y | Y)
                echo "" # Move to next line
                break
                ;;
            *)
                echo ""
                echo ""
                _restore_uninstall_traps
                return 0
                ;;
        esac
    done

    # Enable uninstall mode - allows deletion of data-protected apps (VPNs, dev tools, etc.)
    # that user explicitly chose to uninstall. System-critical components remain protected.
    export MOLE_UNINSTALL_MODE=1

    # Establish sudo once before uninstalling apps that need admin access.
    # Homebrew cask removal can prompt via sudo during uninstall hooks, which
    # does not work reliably under Mole's timed non-interactive execution path.
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]] &&
        { [[ ${#sudo_apps[@]} -gt 0 ]] || [[ ${#brew_cask_apps[@]} -gt 0 ]]; }; then
        local admin_prompt="Admin required to uninstall selected apps"
        if [[ ${#sudo_apps[@]} -gt 0 && ${#brew_cask_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for system apps: ${sudo_apps[*]}"
        elif [[ ${#brew_cask_apps[@]} -gt 0 && ${#sudo_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for Homebrew casks: ${brew_cask_apps[*]}"
        fi

        if ! ensure_sudo_session "$admin_prompt"; then
            echo ""
            log_error "Admin access denied"
            _restore_uninstall_traps
            return 1
        fi
    fi

    # Perform uninstallations with per-app progress feedback
    local success_count=0 failed_count=0 kept_count=0
    local brew_apps_removed=0 # Track successful brew uninstalls for silent autoremove
    local -a failed_items=()
    local -a success_items=()
    local -a kept_items=()
    local -a local_network_warning_apps=()
    local -a system_extension_warning_apps=()
    local current_index=0
    for detail in "${app_details[@]}"; do
        current_index=$((current_index + 1))
        local keep_app="false"
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system has_local_network_usage keep_app <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
        local reason=""
        local suggestion=""

        # Review picker may have left an app with nothing to do (.app kept and
        # every leftover bucket emptied). Log + skip without touching counters
        # or spinner.
        if [[ "$keep_app" == "true" && -z "$related_files" && -z "$system_files" && -z "$diag_system" ]]; then
            echo -e "${GRAY}${ICON_INFO:-→} Skipped ${app_name} (all paths deselected)${NC}"
            continue
        fi

        # Show progress for current app
        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        local action_word="Uninstalling"
        [[ "$keep_app" == "true" ]] && action_word="Cleaning leftovers for"
        if [[ -t 1 ]]; then
            if [[ ${#app_details[@]} -gt 1 ]]; then
                start_inline_spinner "[$current_index/${#app_details[@]}] ${action_word} ${app_name}${brew_tag}..."
            else
                start_inline_spinner "${action_word} ${app_name}${brew_tag}..."
            fi
        fi

        # Always unload Launch Agents/Daemons before removing any plist on disk
        # -- otherwise `remove_file_list` would delete a plist whose daemon is
        # still registered with launchd (zombie until reboot). `stop_launch_services`
        # is unload-only; plist deletion stays owned by `remove_file_list` so the
        # review picker's selection is the source of truth for what survives.
        local has_system_files="false"
        [[ -n "$system_files" ]] && has_system_files="true"
        stop_launch_services "$bundle_id" "$has_system_files" "$app_path"

        if [[ "$keep_app" != "true" ]]; then
            unregister_app_bundle "$app_path"

            # Remove from Login Items
            remove_login_item "$app_name" "$bundle_id"

            if ! force_kill_app "$app_name" "$app_path"; then
                reason="still running"
            fi
        fi

        local used_brew_successfully=false
        if [[ "$keep_app" != "true" ]]; then
            # Keep the spinner alive through the heavy work. For large apps the
            # main bundle delete alone can take many seconds; for apps with
            # 50-200 leftover files the per-file Trash moves add even more. The
            # message is updated so the user sees which phase is running rather
            # than a single static spinner.
            if [[ -t 1 && -z "$reason" ]]; then
                local _phase_size
                _phase_size=$(bytes_to_human "$((total_kb * 1024))")
                local _phase_prefix=""
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    _phase_prefix="[$current_index/${#app_details[@]}] "
                fi
                start_inline_spinner "${_phase_prefix}Removing ${app_name} (${_phase_size})..."
            fi

            if [[ -z "$reason" ]]; then
                if [[ "$is_brew_cask" == "true" && -n "$cask_name" ]]; then
                    # Use brew_uninstall_cask helper (handles env vars, timeout, verification)
                    if brew_uninstall_cask "$cask_name" "$app_path"; then
                        used_brew_successfully=true
                    else
                        # Only fall back to manual app removal when Homebrew no longer
                        # tracks the cask. Otherwise we would recreate the mismatch
                        # where brew still reports the app as installed after Mole
                        # removes the bundle manually.
                        local cask_state=2
                        if command -v is_brew_cask_installed > /dev/null 2>&1; then
                            if is_brew_cask_installed "$cask_name"; then
                                cask_state=0
                            else
                                cask_state=$?
                            fi
                        fi

                        if [[ $cask_state -eq 1 ]]; then
                            if ! mole_delete "$app_path" "$needs_sudo"; then
                                reason="brew cleanup incomplete, manual removal failed"
                            fi
                        elif [[ $cask_state -eq 0 ]]; then
                            reason="brew uninstall failed, package still installed"
                            suggestion="Run brew uninstall --cask --zap $cask_name"
                        else
                            reason="brew uninstall failed, package state unknown"
                            suggestion="Run brew uninstall --cask --zap $cask_name"
                        fi
                    fi
                elif [[ "$needs_sudo" == true ]]; then
                    if [[ -L "$app_path" ]]; then
                        local link_target
                        link_target=$(readlink "$app_path" 2> /dev/null)
                        if [[ -n "$link_target" ]]; then
                            local resolved_target="$link_target"
                            if [[ "$link_target" != /* ]]; then
                                local link_dir
                                link_dir=$(dirname "$app_path")
                                resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") 2> /dev/null || echo ""
                            fi
                            case "$resolved_target" in
                                /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                                    reason="protected system symlink, cannot remove"
                                    ;;
                                *)
                                    if ! mole_delete "$app_path" "true"; then
                                        reason="failed to remove symlink"
                                    fi
                                    ;;
                            esac
                        else
                            if ! mole_delete "$app_path" "true"; then
                                reason="failed to remove symlink"
                            fi
                        fi
                    else
                        if is_uninstall_dry_run; then
                            if ! mole_delete "$app_path" "false"; then
                                reason="dry-run path validation failed"
                            fi
                        else
                            local ret=0
                            mole_delete "$app_path" "true" || ret=$?
                            if [[ $ret -ne 0 ]]; then
                                local diagnosis
                                diagnosis=$(diagnose_removal_failure "$ret" "$app_name")
                                IFS='|' read -r reason suggestion <<< "$diagnosis"
                            fi
                        fi
                    fi
                else
                    if ! mole_delete "$app_path" "false"; then
                        if [[ ! -w "$(dirname "$app_path")" ]]; then
                            reason="parent directory not writable"
                        else
                            reason="remove failed, check permissions"
                        fi
                    fi
                fi
            fi
        fi

        # Remove related files if app removal succeeded.
        if [[ -z "$reason" ]]; then
            if [[ -t 1 ]]; then
                local _phase_prefix=""
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    _phase_prefix="[$current_index/${#app_details[@]}] "
                fi
                start_inline_spinner "${_phase_prefix}Cleaning files for ${app_name}..."
            fi
            remove_file_list "$related_files" "false" > /dev/null

            # Identify leftovers (silent rm failures, e.g. container directories
            # macOS protects via com.apple.provenance xattr). Compute their
            # total size in a single du invocation rather than walking each
            # path; the source paths that DID move to Trash are already gone
            # and would just produce stderr noise we discard.
            local leftover_kb=0
            local -a leftover_paths=()
            while IFS= read -r _lf; do
                [[ -n "$_lf" && -e "$_lf" ]] || continue
                # Skip macOS-managed container stubs: containermanagerd protects
                # these directories via com.apple.provenance xattr; rm -rf always
                # fails on them by design. User data is already gone at this point.
                if [[ "$_lf" == */Library/Containers/* && -f "$_lf/.com.apple.containermanagerd.metadata.plist" ]]; then
                    continue
                fi
                leftover_paths+=("$_lf")
            done <<< "$related_files"

            if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                local _du_total
                _du_total=$(command du -skcP "${leftover_paths[@]}" 2> /dev/null | awk 'END {print $1}')
                if [[ "$_du_total" =~ ^[0-9]+$ ]]; then
                    leftover_kb=$_du_total
                fi
            fi

            if [[ -t 1 ]]; then
                start_inline_spinner "${_phase_prefix}Cleaning system files for ${app_name}..."
            fi
            if [[ "$used_brew_successfully" == "true" ]]; then
                remove_file_list "$diag_system" "true" > /dev/null
            else
                local system_all="$system_files"
                if [[ -n "$diag_system" ]]; then
                    if [[ -n "$system_all" ]]; then
                        system_all+=$'\n'
                    fi
                    system_all+="$diag_system"
                fi
                remove_file_list "$system_all" "true" > /dev/null
            fi

            # Defaults writes are side effects that should never run in dry-run mode.
            # Skip when the user kept the .app; they remain in control of its
            # preference surface and only chose to drop specific files.
            if [[ "$keep_app" != "true" && -n "$bundle_id" && "$bundle_id" != "unknown" ]]; then
                if is_uninstall_dry_run; then
                    debug_log "[DRY RUN] Would clear defaults domain: $bundle_id"
                else
                    if defaults read "$bundle_id" &> /dev/null; then
                        defaults delete "$bundle_id" 2> /dev/null || true
                    fi
                fi

                # ByHost preferences (machine-specific).
                if [[ -d "$HOME/Library/Preferences/ByHost" ]]; then
                    if [[ "$bundle_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
                        while IFS= read -r -d '' plist_file; do
                            mole_delete "$plist_file" "true" || true
                        done < <(command find "$HOME/Library/Preferences/ByHost" -maxdepth 1 -type f -name "${bundle_id}.*.plist" -print0 2> /dev/null || true)
                    else
                        debug_log "Skipping ByHost cleanup, invalid bundle id: $bundle_id"
                    fi
                fi
            fi

            # All per-app side effects done; tear the spinner down before
            # any echo so the success line does not collide with the spinner.
            [[ -t 1 ]] && stop_inline_spinner

            # Show success
            local _kept_suffix=""
            [[ "$keep_app" == "true" ]] && _kept_suffix=" ${GRAY}(kept .app)${NC}"
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} [$current_index/${#app_details[@]}] ${app_name}${_kept_suffix}"
                else
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} ${app_name}${_kept_suffix}"
                fi
            fi

            # Warn about files that could not be removed and exclude them from freed total.
            if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                for _lpath in "${leftover_paths[@]}"; do
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Could not remove: ${_lpath/$HOME/~}"
                done
                total_kb=$((total_kb - leftover_kb))
                ((total_kb < 0)) && total_kb=0
            fi

            total_size_freed=$((total_size_freed + total_kb))
            [[ "$used_brew_successfully" == "true" ]] && brew_apps_removed=$((brew_apps_removed + 1))
            files_cleaned=$((files_cleaned + 1))
            total_items=$((total_items + 1))
            if [[ "$keep_app" == "true" ]]; then
                kept_count=$((kept_count + 1))
                kept_items+=("$app_path")
            else
                success_count=$((success_count + 1))
                success_items+=("$app_path")
                if [[ "$has_local_network_usage" == "true" ]]; then
                    local_network_warning_apps+=("$app_name")
                fi

                # Check for orphaned system extensions (camera, network, endpoint security, etc.)
                if [[ -n "$bundle_id" && "$bundle_id" != "unknown" && "$bundle_id" =~ ^[A-Za-z0-9._-]+$ && -d /Library/SystemExtensions ]]; then
                    if command find /Library/SystemExtensions -maxdepth 3 -name "*.systemextension" -path "*${bundle_id}*" -print -quit 2> /dev/null | grep -q .; then
                        system_extension_warning_apps+=("$app_name")
                    fi
                fi
            fi
        else
            # Stop spinner before printing the failure line so the error
            # message is not painted over by the spinner's next tick.
            [[ -t 1 ]] && stop_inline_spinner
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${ICON_ERROR} [$current_index/${#app_details[@]}] ${app_name} ${GRAY}, $reason${NC}"
                else
                    echo -e "${ICON_ERROR} ${app_name} failed: $reason"
                fi
                if [[ -n "${suggestion:-}" ]]; then
                    echo -e "${GRAY}   ${ICON_REVIEW} ${suggestion}${NC}"
                fi
            fi

            failed_count=$((failed_count + 1))
            failed_items+=("$app_name:$reason:${suggestion:-}")
        fi
    done

    # Summary
    local freed_display
    freed_display=$(bytes_to_human "$((total_size_freed * 1024))")

    local summary_status="success"
    local -a summary_details=()

    if [[ $success_count -gt 0 ]]; then
        local success_text="app"
        [[ $success_count -gt 1 ]] && success_text="apps"
        local success_line="Removed ${success_count} ${success_text}"
        if is_uninstall_dry_run; then
            success_line="Would remove ${success_count} ${success_text}"
        fi
        if [[ -n "$freed_display" ]]; then
            if is_uninstall_dry_run; then
                success_line+=", would free ${GREEN}${freed_display}${NC}"
            else
                success_line+=", freed ${GREEN}${freed_display}${NC}"
            fi
        fi

        # Format app list with max 3 per line.
        if [[ ${#success_items[@]} -gt 0 ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for success_path in "${success_items[@]}"; do
                local display_name
                display_name=$(basename "$success_path" .app)
                local display_item="${GREEN}${display_name}${NC}"

                if ((idx % 3 == 0)); then
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        current_line="${success_line}: $display_item"
                        is_first_line=false
                    else
                        current_line="$display_item"
                    fi
                else
                    current_line="$current_line, $display_item"
                fi
                idx=$((idx + 1))
            done
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$success_line")
        fi
    fi

    if [[ $kept_count -gt 0 ]]; then
        local kept_text="app"
        [[ $kept_count -gt 1 ]] && kept_text="apps"
        local kept_line="Cleaned leftovers for ${kept_count} ${kept_text} (kept .app)"
        if is_uninstall_dry_run; then
            kept_line="Would clean leftovers for ${kept_count} ${kept_text} (kept .app)"
        fi

        if [[ ${#kept_items[@]} -gt 0 ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for kept_path in "${kept_items[@]}"; do
                local display_name
                display_name=$(basename "$kept_path" .app)
                local display_item="${YELLOW}${display_name}${NC}"

                if ((idx % 3 == 0)); then
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        current_line="${kept_line}: $display_item"
                        is_first_line=false
                    else
                        current_line="$display_item"
                    fi
                else
                    current_line="$current_line, $display_item"
                fi
                idx=$((idx + 1))
            done
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$kept_line")
        fi
    fi

    if [[ $failed_count -gt 0 ]]; then
        summary_status="warn"

        local failed_names=()
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        local reason_summary="could not be removed"
        local suggestion_text=""
        if [[ $failed_count -eq 1 ]]; then
            # Extract reason and suggestion from format: app:reason:suggestion
            local item="${failed_items[0]}"
            local without_app="${item#*:}"
            local first_reason="${without_app%%:*}"
            local first_suggestion="${without_app#*:}"

            # If suggestion is same as reason, there was no suggestion part
            # Also check if suggestion is empty
            if [[ "$first_suggestion" != "$first_reason" && -n "$first_suggestion" ]]; then
                suggestion_text="${GRAY}${ICON_REVIEW} ${first_suggestion}${NC}"
            fi

            case "$first_reason" in
                still*running*) reason_summary="is still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*denied*) reason_summary="permission denied" ;;
                owned*by*) reason_summary="$first_reason, try with sudo" ;;
                *) reason_summary="$first_reason" ;;
            esac
        fi
        summary_details+=("${ICON_LIST} Failed: ${RED}${failed_list}${NC} ${reason_summary}")
        if [[ -n "$suggestion_text" ]]; then
            summary_details+=("$suggestion_text")
        fi
    fi

    if [[ $success_count -eq 0 && $failed_count -eq 0 && $kept_count -eq 0 ]]; then
        summary_status="info"
        summary_details+=("No applications were uninstalled.")
    fi

    if [[ ${#local_network_warning_apps[@]} -gt 0 ]]; then
        local local_network_list=""
        local idx
        for ((idx = 0; idx < ${#local_network_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && local_network_list+=", "
            local_network_list+="${local_network_warning_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} Local Network permissions on macOS 15+ can outlive app removal: ${YELLOW}${local_network_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Mole does not reset ${GRAY}/Volumes/Data/Library/Preferences/com.apple.networkextension*.plist${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} If stale or duplicate entries remain, clear them manually in Recovery mode because the reset is global${NC}")
    fi

    if [[ ${#system_extension_warning_apps[@]} -gt 0 ]]; then
        local ext_list=""
        local idx
        for ((idx = 0; idx < ${#system_extension_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && ext_list+=", "
            ext_list+="${system_extension_warning_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} System extensions may remain after removal: ${YELLOW}${ext_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Check ${GRAY}System Settings > General > Login Items & Extensions${NC} to remove leftover extensions")
    fi

    local title="Uninstall complete"
    if [[ "$summary_status" == "warn" ]]; then
        title="Uninstall incomplete"
    fi
    if is_uninstall_dry_run; then
        title="Uninstall dry run complete"
    fi

    echo ""
    print_summary_block "$title" "${summary_details[@]}"
    printf '\n'

    # Run brew autoremove silently in background to avoid interrupting UX.
    if [[ $brew_apps_removed -gt 0 && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        (
            HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
                run_with_timeout 30 brew autoremove > /dev/null 2>&1 || true
        ) &
        disown $! 2> /dev/null || true
    fi

    # Clean up Dock entries for uninstalled apps.
    if [[ $success_count -gt 0 && ${#success_items[@]} -gt 0 ]]; then
        if is_uninstall_dry_run; then
            log_info "[DRY RUN] Would refresh LaunchServices and update Dock entries"
        else
            (
                remove_apps_from_dock "${success_items[@]}" > /dev/null 2>&1 || true
                refresh_launch_services_after_uninstall > /dev/null 2>&1 || true
            ) &
            disown $! 2> /dev/null || true
        fi
    fi

    _cleanup_sudo_keepalive

    # Disable uninstall mode
    unset MOLE_UNINSTALL_MODE

    _restore_uninstall_traps
    unset -f _restore_uninstall_traps

    total_size_cleaned=$((total_size_cleaned + total_size_freed))
    unset failed_items
}
