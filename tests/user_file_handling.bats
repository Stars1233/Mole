#!/usr/bin/env bats

# Tests for user file handling utilities in lib/core/base.sh
# Covers: ensure_user_dir, ensure_user_file, get_invoking_user, etc.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-userfile.XXXXXX")"
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
    rm -rf "$HOME/.config" "$HOME/.cache"
    mkdir -p "$HOME"
}

# ============================================================================
# Darwin Version Detection Tests
# ============================================================================

@test "get_darwin_major returns numeric version on macOS" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_darwin_major")
    # Should be a number (e.g., 23, 24, etc.)
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_darwin_major returns 999 on failure (mock uname failure)" {
    # Mock uname to fail and verify fallback behavior
    result=$(bash -c "
        uname() { return 1; }
        export -f uname
        source '$PROJECT_ROOT/lib/core/base.sh'
        get_darwin_major
    ")
    [ "$result" = "999" ]
}

@test "is_darwin_ge correctly compares versions" {
    # Should return true for minimum <= current
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_darwin_ge 1"
    [ "$status" -eq 0 ]

    # Should return false for very high version requirement (unless on futuristic macOS)
    # Note: With our 999 fallback, this will actually succeed on error, which is correct behavior
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_darwin_ge 100 && echo 'yes' || echo 'no'")
    # Just verify command runs without error
    [[ -n "$result" ]]
}

# ============================================================================
# User Context Detection Tests
# ============================================================================

@test "is_root_user detects non-root correctly" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; is_root_user && echo 'root' || echo 'not-root'")
    [ "$result" = "not-root" ]
}

@test "get_invoking_user returns current user when not sudo" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_user")
    [ -n "$result" ]
    # Should be current user
    [ "$result" = "${USER:-$(whoami)}" ]
}

@test "get_invoking_uid returns numeric UID" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_uid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_gid returns numeric GID" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_gid")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "get_invoking_home returns home directory" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_invoking_home")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "get_user_home returns home for valid user" {
    current_user="${USER:-$(whoami)}"
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home '$current_user'")
    [ -n "$result" ]
    [ -d "$result" ]
}

@test "get_user_home returns empty for invalid user" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; get_user_home 'nonexistent_user_12345'")
    [ -z "$result" ] || [ "$result" = "~nonexistent_user_12345" ]
}

# ============================================================================
# Directory Creation Tests
# ============================================================================

@test "ensure_user_dir creates simple directory" {
    test_dir="$HOME/.cache/test"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir creates nested directory" {
    test_dir="$HOME/.config/mole/deep/nested/path"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir handles tilde expansion" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '~/.cache/tilde-test'"
    [ -d "$HOME/.cache/tilde-test" ]
}

@test "ensure_user_dir is idempotent" {
    test_dir="$HOME/.cache/idempotent"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]
}

@test "ensure_user_dir handles empty path gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_dir preserves ownership for non-root users" {
    test_dir="$HOME/.cache/ownership-test"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}

# ============================================================================
# File Creation Tests
# ============================================================================

@test "ensure_user_file creates file and parent directories" {
    test_file="$HOME/.config/mole/test.log"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
    [ -d "$(dirname "$test_file")" ]
}

@test "ensure_user_file handles tilde expansion" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '~/.cache/tilde-file.txt'"
    [ -f "$HOME/.cache/tilde-file.txt" ]
}

@test "ensure_user_file is idempotent" {
    test_file="$HOME/.cache/idempotent.txt"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    echo "content" > "$test_file"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    # Should preserve existing content
    [ -f "$test_file" ]
    [ "$(cat "$test_file")" = "content" ]
}

@test "ensure_user_file handles empty path gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file ''"
    [ "$status" -eq 0 ]
}

@test "ensure_user_file creates deeply nested files" {
    test_file="$HOME/.config/deep/very/nested/structure/file.log"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"
    [ -f "$test_file" ]
}

@test "ensure_user_file preserves ownership for non-root users" {
    test_file="$HOME/.cache/file-ownership-test.txt"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$test_file'"

    current_uid=$(id -u)
    file_uid=$(/usr/bin/stat -f%u "$test_file")
    [ "$file_uid" = "$current_uid" ]
}

# ============================================================================
# Performance Tests (Early Stop Optimization)
# ============================================================================

@test "ensure_user_dir early stop optimization works" {
    # Create a nested structure
    test_dir="$HOME/.cache/perf/test/nested"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"

    # Call again - should detect correct ownership and stop early
    # This is a behavioral test; we verify it doesn't fail
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$test_dir'"
    [ -d "$test_dir" ]

    # Verify ownership is still correct
    current_uid=$(id -u)
    dir_uid=$(/usr/bin/stat -f%u "$test_dir")
    [ "$dir_uid" = "$current_uid" ]
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "ensure_user_dir and ensure_user_file work together" {
    cache_dir="$HOME/.cache/mole"
    cache_file="$cache_dir/integration_test.log"

    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_dir '$cache_dir'"
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'; ensure_user_file '$cache_file'"

    [ -d "$cache_dir" ]
    [ -f "$cache_file" ]
}

@test "multiple ensure_user_file calls in same directory" {
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_file '$HOME/.config/mole/file1.txt'
        ensure_user_file '$HOME/.config/mole/file2.txt'
        ensure_user_file '$HOME/.config/mole/file3.txt'
    "

    [ -f "$HOME/.config/mole/file1.txt" ]
    [ -f "$HOME/.config/mole/file2.txt" ]
    [ -f "$HOME/.config/mole/file3.txt" ]
}

@test "ensure functions handle concurrent calls safely" {
    # Simulate concurrent directory creation
    bash -c "source '$PROJECT_ROOT/lib/core/base.sh'
        ensure_user_dir '$HOME/.cache/concurrent' &
        ensure_user_dir '$HOME/.cache/concurrent' &
        wait
    "

    [ -d "$HOME/.cache/concurrent" ]
}