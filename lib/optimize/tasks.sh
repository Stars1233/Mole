#!/bin/bash
# Optimization Tasks

set -euo pipefail

# Configuration constants
# MOLE_TM_THIN_TIMEOUT: Max seconds to wait for tmutil thinning (default: 180)
# MOLE_TM_THIN_VALUE: Bytes to thin for local snapshots (default: 9999999999)
# MOLE_MAIL_DOWNLOADS_MIN_KB: Minimum size in KB before cleaning Mail attachments (default: 5120)
# MOLE_MAIL_AGE_DAYS: Minimum age in days for Mail attachments to be cleaned (default: 30)
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999

flush_dns_cache() {
    sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null
}

# Rebuild databases and flush caches
opt_system_maintenance() {
    local -a results=()
    local darwin_major
    darwin_major=$(get_darwin_major)

    if flush_dns_cache; then
        results+=("${GREEN}✓${NC} DNS cache flushed")
    fi

    local spotlight_status
    spotlight_status=$(mdutil -s / 2> /dev/null || echo "")
    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        results+=("${GRAY}${ICON_EMPTY}${NC} Spotlight indexing disabled")
    else
        results+=("${GREEN}✓${NC} Spotlight index verified")
    fi

    for result in "${results[@]}"; do
        echo -e "  $result"
    done
}

# Refresh Finder and Safari caches
opt_cache_refresh() {
    qlmanage -r cache > /dev/null 2>&1 || true
    qlmanage -r > /dev/null 2>&1 || true

    local refreshed=0
    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
        "$HOME/Library/Caches/com.apple.iconservices.store"
        "$HOME/Library/Caches/com.apple.iconservices"
        "$HOME/Library/Caches/com.apple.Safari/WebKitCache"
        "$HOME/Library/Caches/com.apple.Safari/Favicon"
    )

    for target_path in "${cache_targets[@]}"; do
        if [[ -e "$target_path" ]]; then
            if ! should_protect_path "$target_path"; then
                if safe_remove "$target_path" true; then
                    ((refreshed++))
                fi
            fi
        fi
    done

    echo -e "  ${GREEN}✓${NC} QuickLook thumbnails refreshed"
    echo -e "  ${GREEN}✓${NC} Icon services cache rebuilt"
    echo -e "  ${GREEN}✓${NC} Safari web cache optimized"
}

# Run periodic maintenance scripts
opt_maintenance_scripts() {
    if run_with_timeout 120 sudo newsyslog > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} System logs rotated"
    else
        echo -e "  ${YELLOW}!${NC} Failed to rotate logs"
    fi
}

# Refresh wireless interfaces
opt_radio_refresh() {
    # Only restart Bluetooth service, do NOT delete pairing information
    if sudo pkill -HUP bluetoothd 2> /dev/null; then
        echo -e "  ${GREEN}✓${NC} Bluetooth controller refreshed"
    fi

    local wifi_interface
    wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}' | head -1)
    if [[ -n "$wifi_interface" ]]; then
        if sudo bash -c "trap '' INT TERM; ifconfig '$wifi_interface' down; sleep 1; ifconfig '$wifi_interface' up" 2> /dev/null; then
            echo -e "  ${GREEN}✓${NC} Wi-Fi interface reset"
        fi
    fi

    # Restart AirDrop interface
    sudo bash -c "trap '' INT TERM; ifconfig awdl0 down; ifconfig awdl0 up" 2> /dev/null || true
    echo -e "  ${GREEN}✓${NC} AirDrop service restarted"
}

# Saved state: remove OLD app saved states (7+ days)
opt_saved_state_cleanup() {
    local state_dir="$HOME/Library/Saved Application State"

    if [[ -d "$state_dir" ]]; then
        while IFS= read -r -d '' state_path; do
            if should_protect_path "$state_path"; then
                continue
            fi
            safe_remove "$state_path" true > /dev/null 2>&1
        done < <(command find "$state_dir" -type d -name "*.savedState" -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 2> /dev/null)
    fi

    echo -e "  ${GREEN}✓${NC} App saved states optimized"
}

# Swap cleanup: reset swap files
opt_swap_cleanup() {
    if sudo launchctl unload /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1; then
        sudo launchctl load /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} Swap cache reset"
    else
        echo -e "  ${YELLOW}!${NC} Failed to reset swap"
    fi
}

# Startup cache: rebuild kernel caches (handled automatically by modern macOS)
opt_startup_cache() {
    echo -e "  ${GRAY}-${NC} Startup cache (auto-managed by macOS)"
}

# Local snapshots: thin Time Machine snapshots
opt_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "${YELLOW}!${NC} tmutil not available on this system"
        return
    fi

    local before after
    before=$(count_local_snapshots)
    if [[ "$before" -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No local snapshots to thin"
        return
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    local success=false
    local exit_code=0
    set +e
    run_with_timeout "$MOLE_TM_THIN_TIMEOUT" sudo tmutil thinlocalsnapshots / "$MOLE_TM_THIN_VALUE" 4 > /dev/null 2>&1
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
        success=true
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    after=$(count_local_snapshots)
    local removed=$((before - after))
    [[ "$removed" -lt 0 ]] && removed=0

    if [[ "$success" == "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $removed snapshots (remaining: $after)"
    elif [[ "$exit_code" -eq 124 ]]; then
        echo -e "${YELLOW}!${NC} Timed out after ${MOLE_TM_THIN_TIMEOUT}s"
    else
        echo -e "${YELLOW}!${NC} Failed with exit code $exit_code"
    fi
}

# Fix broken system configurations
# Repairs corrupted preference files and broken login items
opt_fix_broken_configs() {
    local broken_prefs=$(fix_broken_preferences)
    local broken_items=$(fix_broken_login_items)

    if [[ $broken_prefs -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Repaired $broken_prefs corrupted preference files"
    else
        echo -e "  ${GREEN}✓${NC} All preference files valid"
    fi

    if [[ $broken_items -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Removed $broken_items broken login items"
    else
        echo -e "  ${GREEN}✓${NC} All login items functional"
    fi
}

# Network cache optimization
opt_network_optimization() {
    flush_dns_cache
    echo -e "  ${GREEN}✓${NC} DNS cache refreshed"

    if sudo arp -d -a > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ARP cache rebuilt"
    fi

    echo -e "  ${GREEN}✓${NC} mDNSResponder optimized"
}

# SQLite database optimization
# Runs VACUUM on safe user-level databases to reduce size and improve performance
# Only operates on databases that are not in use and meet size threshold
opt_sqlite_vacuum() {
    local optimized_count=0
    local total_saved_kb=0
    local min_size_kb=1024 # Only optimize databases larger than 1MB

    # List of safe databases to optimize
    # Exclude critical system databases like Mail, Messages, Photos
    local -a safe_databases=(
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Safari/CloudTabs.db"
    )

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning databases..."
    fi

    for db_path in "${safe_databases[@]}"; do
        # Check if database exists
        [[ ! -f "$db_path" ]] && continue

        # Check if it's a SQLite database
        if ! file "$db_path" 2> /dev/null | grep -q "SQLite"; then
            continue
        fi

        # Check size threshold
        local db_size_kb
        db_size_kb=$(get_path_size_kb "$db_path")
        [[ $db_size_kb -lt $min_size_kb ]] && continue

        # Check if database is in use
        if lsof "$db_path" > /dev/null 2>&1; then
            debug_log "Skipping $db_path - in use"
            continue
        fi

        # Check disk space (VACUUM needs ~2x database size as temporary space)
        local free_space_kb
        free_space_kb=$(df -k "$(dirname "$db_path")" | tail -1 | awk '{print $4}')
        if [[ $free_space_kb -lt $((db_size_kb * 2)) ]]; then
            debug_log "Skipping $db_path - insufficient disk space"
            continue
        fi

        # Verify database integrity before VACUUM
        if ! sqlite3 "$db_path" "PRAGMA integrity_check;" 2> /dev/null | grep -q "ok"; then
            debug_log "Skipping $db_path - integrity check failed"
            continue
        fi

        # Get size before optimization
        local size_before=$db_size_kb

        # Perform VACUUM with error handling
        if sqlite3 "$db_path" "VACUUM;" 2> /dev/null; then
            # Verify database integrity after VACUUM
            if ! sqlite3 "$db_path" "PRAGMA integrity_check;" 2> /dev/null | grep -q "ok"; then
                debug_log "Warning: $db_path integrity check failed after VACUUM"
                continue
            fi

            # Get size after optimization
            local size_after
            size_after=$(get_path_size_kb "$db_path")
            local saved_kb=$((size_before - size_after))

            if [[ $saved_kb -gt 0 ]]; then
                ((optimized_count++))
                ((total_saved_kb += saved_kb))
            fi
        else
            debug_log "Failed to VACUUM $db_path"
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $optimized_count -gt 0 ]]; then
        local saved_human=$(bytes_to_human "$((total_saved_kb * 1024))")
        echo -e "  ${GREEN}✓${NC} Optimized $optimized_count databases ($saved_human saved)"
    else
        echo -e "  ${GREEN}✓${NC} Databases already optimized"
    fi
}

# Clean Spotlight user caches

# Execute optimization by action name
execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        maintenance_scripts) opt_maintenance_scripts ;;
        radio_refresh) opt_radio_refresh ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        swap_cleanup) opt_swap_cleanup ;;
        startup_cache) opt_startup_cache ;;
        local_snapshots) opt_local_snapshots ;;
        fix_broken_configs) opt_fix_broken_configs ;;
        network_optimization) opt_network_optimization ;;
        sqlite_vacuum) opt_sqlite_vacuum ;;
        *)
            echo -e "${YELLOW}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
