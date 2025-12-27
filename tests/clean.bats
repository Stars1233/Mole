#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="xterm-256color"
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/Library" "$HOME/.config"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
}

@test "mo clean --dry-run skips system cleanup in non-interactive mode" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run Mode"* ]]
    [[ "$output" != *"Deep system-level cleanup"* ]]
}

@test "mo clean --dry-run reports user cache without deleting it" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"User app cache"* ]]
    [[ "$output" == *"Potential space"* ]]
    [ -f "$HOME/Library/Caches/TestApp/cache.tmp" ]
}

@test "mo clean honors whitelist entries" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/mole/whitelist" << EOF
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]]
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "mo clean protects Maven repository by default" {
    mkdir -p "$HOME/.m2/repository/org/example"
    echo "dependency" > "$HOME/.m2/repository/org/example/lib.jar"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [ -f "$HOME/.m2/repository/org/example/lib.jar" ]
    [[ "$output" != *"Maven repository cache"* ]]
}

@test "mo clean respects MO_BREW_TIMEOUT environment variable" {
    if ! command -v brew > /dev/null 2>&1; then
        skip "Homebrew not installed"
    fi

    run env HOME="$HOME" MO_BREW_TIMEOUT=5 "$PROJECT_ROOT/bin/clean.sh" --dry-run
    [ "$status" -eq 0 ]
}

@test "FINDER_METADATA_SENTINEL in whitelist protects .DS_Store files" {
    mkdir -p "$HOME/Documents"
    touch "$HOME/Documents/.DS_Store"

    cat > "$HOME/.config/mole/whitelist" << EOF
FINDER_METADATA_SENTINEL
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"protected by whitelist"* ]]
    [ -f "$HOME/Documents/.DS_Store" ]
}

@test "clean_recent_items removes shared file lists" {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    mkdir -p "$shared_dir"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() {
    echo "safe_clean $1"
}
clean_recent_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent"* ]]
}

@test "clean_recent_items handles missing shared directory" {
    rm -rf "$HOME/Library/Application Support/com.apple.sharedfilelist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() {
    echo "safe_clean $1"
}
clean_recent_items
EOF

    [ "$status" -eq 0 ]
}

@test "clean_mail_downloads skips cleanup when size below threshold" {
    mkdir -p "$HOME/Library/Mail Downloads"
    echo "test" > "$HOME/Library/Mail Downloads/small.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Mail Downloads/small.txt" ]
}

@test "clean_mail_downloads removes old attachments" {
    mkdir -p "$HOME/Library/Mail Downloads"
    touch "$HOME/Library/Mail Downloads/old.pdf"
    # Make file old (31+ days)
    touch -t 202301010000 "$HOME/Library/Mail Downloads/old.pdf"

    # Create large enough size to trigger cleanup (>5MB threshold)
    dd if=/dev/zero of="$HOME/Library/Mail Downloads/dummy.dat" bs=1024 count=6000 2>/dev/null

    # Verify file exists before cleanup
    [ -f "$HOME/Library/Mail Downloads/old.pdf" ]

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    # Verify old file was actually removed
    [ ! -f "$HOME/Library/Mail Downloads/old.pdf" ]
}
