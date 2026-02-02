#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-brew-uninstall-home.XXXXXX")"
    export HOME
}

teardown_file() {
    rm -rf "$HOME"
    export HOME="$ORIGINAL_HOME"
}

setup() {
    mkdir -p "$HOME/Applications"
    mkdir -p "$HOME/Library/Caches"
    # Create fake Caskroom
    mkdir -p "$HOME/Caskroom/test-app/1.2.3/TestApp.app"
}

@test "get_brew_cask_name detects app in Caskroom (simulated)" {
    # Create fake Caskroom structure with symlink (modern Homebrew style)
    mkdir -p "$HOME/Caskroom/test-app/1.0.0"
    mkdir -p "$HOME/Applications/TestApp.app"
    ln -s "$HOME/Applications/TestApp.app" "$HOME/Caskroom/test-app/1.0.0/TestApp.app"

    run bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

# Override the function to use our test Caskroom
get_brew_cask_name() {
    local app_path="\$1"
    [[ -z "\$app_path" || ! -d "\$app_path" ]] && return 1
    command -v brew > /dev/null 2>&1 || return 1

    local app_bundle_name=\$(basename "\$app_path")
    local cask_match
    # Use test Caskroom
    cask_match=\$(find "$HOME/Caskroom" -maxdepth 3 -name "\$app_bundle_name" 2> /dev/null | head -1 || echo "")
    if [[ -n "\$cask_match" ]]; then
        local relative="\${cask_match#$HOME/Caskroom/}"
        echo "\${relative%%/*}"
        return 0
    fi
    return 1
}

get_brew_cask_name "$HOME/Applications/TestApp.app"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "test-app" ]]
}

@test "get_brew_cask_name handles non-brew apps" {
    mkdir -p "$HOME/Applications/ManualApp.app"

    result=$(bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
# Mock brew to return nothing for this
brew() { return 1; }
export -f brew
get_brew_cask_name "$HOME/Applications/ManualApp.app" || echo "not_found"
EOF
    )

    [[ "$result" == "not_found" ]]
}

@test "batch_uninstall_applications uses brew uninstall for casks (mocked)" {
    # Setup fake app
    local app_bundle="$HOME/Applications/BrewApp.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

# Mock dependencies
request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
remove_apps_from_dock() { :; }
force_kill_app() { return 0; }
run_with_timeout() { shift; "$@"; }
export -f run_with_timeout

# Mock brew to track calls
brew() {
    echo "brew call: $*" >> "$HOME/brew_calls.log"
    return 0
}
export -f brew

# Mock get_brew_cask_name to return a name
get_brew_cask_name() { echo "brew-app-cask"; return 0; }
export -f get_brew_cask_name

selected_apps=("0|$HOME/Applications/BrewApp.app|BrewApp|com.example.brewapp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

# Simulate 'Enter' for confirmation
printf '\n' | batch_uninstall_applications > /dev/null 2>&1

grep -q "uninstall --cask --zap brew-app-cask" "$HOME/brew_calls.log"
EOF

    [ "$status" -eq 0 ]
}
