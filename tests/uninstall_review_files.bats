#!/usr/bin/env bats

# Tests for the per-file deselect review flow added for issue #852:
# - `interactive_review_files` flattens / re-encodes `app_details`
# - `_recompute_uninstall_aggregates` derives sudo / brew_cask state
# - the confirm prompt now exposes the `R review` keystroke

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-review.XXXXXX")"
    export SANDBOX
    HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    export HOME
    export MOLE_TEST_NO_AUTH=1
}

teardown() {
    rm -rf "$SANDBOX"
}

# Shared prelude: load batch.sh, neutralize the interactive menu, and provide a
# tiny helper to encode a newline-joined path list the way `app_details` rows
# expect.
prelude() {
    cat <<EOF
set -euo pipefail
export MOLE_TEST_NO_AUTH=1
export HOME="$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

paginated_multi_select() {
    return "\${STUB_PAGINATED_RC:-0}"
}

enc() {
    if [[ -z "\$1" ]]; then
        printf ''
    else
        printf '%s' "\$1" | base64 | tr -d '\n'
    fi
}
EOF
}

@test "interactive_review_files returns 0 with empty app_details and no menu call" {
    run bash --noprofile --norc <<EOF
$(prelude)
app_details=()
called=0
paginated_multi_select() { called=1; return 0; }
interactive_review_files
echo "rc=\$?"
echo "called=\$called"
echo "count=\${#app_details[@]}"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"called=0"* ]]
    [[ "$output" == *"count=0"* ]]
}

@test "interactive_review_files returns 1 and leaves app_details untouched on picker cancel" {
    run bash --noprofile --norc <<EOF
$(prelude)
related="\$HOME/Library/Preferences/com.x.plist"
mkdir -p "\$(dirname "\$related")"
: > "\$related"
encoded="\$(enc "\$related")"
original="App|/Applications/App.app|com.x|100|\$encoded|||false|false|||false|false"
app_details=("\$original")
paginated_multi_select() { return 1; }
rc=0
interactive_review_files || rc=\$?
echo "rc=\$rc"
[[ "\${app_details[0]}" == "\$original" ]] && echo "unchanged=true" || echo "unchanged=false"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"unchanged=true"* ]]
}

@test "interactive_review_files keeps every preselected row when MOLE_SELECTION_RESULT echoes them all back" {
    run bash --noprofile --norc <<EOF
$(prelude)
mkdir -p "\$HOME/Library/Preferences"
f1="\$HOME/Library/Preferences/com.x.plist"
f2="\$HOME/Library/Preferences/com.x.helper.plist"
: > "\$f1"; : > "\$f2"
related_in="\$f1
\$f2"
encoded="\$(enc "\$related_in")"
app_details=("App|/Applications/App.app|com.x|100|\$encoded|||false|false|||false|false")
paginated_multi_select() {
    # 3 rows: app(0), related f1(1), related f2(2). Keep all selected.
    MOLE_SELECTION_RESULT="0,1,2"
    return 0
}
interactive_review_files
echo "rc=\$?"
IFS='|' read -r _ _ _ _ enc_related _ _ _ _ _ _ _ keep_app <<< "\${app_details[0]}"
echo "keep_app=\$keep_app"
echo "decoded:"
printf '%s' "\$enc_related" | base64 -d
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"keep_app=false"* ]]
    [[ "$output" == *"com.x.plist"* ]]
    [[ "$output" == *"com.x.helper.plist"* ]]
}

@test "interactive_review_files drops a deselected related file and re-encodes the survivors" {
    run bash --noprofile --norc <<EOF
$(prelude)
mkdir -p "\$HOME/Library/Preferences"
f1="\$HOME/Library/Preferences/com.x.plist"
f2="\$HOME/Library/Preferences/com.x.helper.plist"
: > "\$f1"; : > "\$f2"
related_in="\$f1
\$f2"
encoded="\$(enc "\$related_in")"
app_details=("App|/Applications/App.app|com.x|100|\$encoded|||false|false|||false|false")
paginated_multi_select() {
    # Drop row 1 (the f1 preference). Keep app(0) and helper(2).
    MOLE_SELECTION_RESULT="0,2"
    return 0
}
interactive_review_files
IFS='|' read -r _ _ _ _ enc_related _ _ _ _ _ _ _ keep_app <<< "\${app_details[0]}"
echo "keep_app=\$keep_app"
decoded="\$(printf '%s' "\$enc_related" | base64 -d)"
echo "decoded=\$decoded"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep_app=false"* ]]
    [[ "$output" == *"com.x.helper.plist"* ]]
    [[ "$output" != *"com.x.plist
"* ]]  # bare com.x.plist line should be gone
}

@test "deselecting the .app row flips keep_app=true while leaving related files intact" {
    run bash --noprofile --norc <<EOF
$(prelude)
mkdir -p "\$HOME/Library/Preferences"
f1="\$HOME/Library/Preferences/com.x.plist"
: > "\$f1"
encoded="\$(enc "\$f1")"
app_details=("App|/Applications/App.app|com.x|100|\$encoded|||false|false|||false|false")
paginated_multi_select() {
    # Row 0 = .app (deselected). Row 1 = related file (kept).
    MOLE_SELECTION_RESULT="1"
    return 0
}
interactive_review_files
IFS='|' read -r _ _ _ _ enc_related _ _ _ _ _ _ _ keep_app <<< "\${app_details[0]}"
echo "keep_app=\$keep_app"
decoded="\$(printf '%s' "\$enc_related" | base64 -d)"
echo "decoded=\$decoded"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep_app=true"* ]]
    [[ "$output" == *"com.x.plist"* ]]
}

@test "deselecting every row marks keep_app=true with empty buckets" {
    run bash --noprofile --norc <<EOF
$(prelude)
mkdir -p "\$HOME/Library/Preferences"
f1="\$HOME/Library/Preferences/com.x.plist"
: > "\$f1"
encoded="\$(enc "\$f1")"
app_details=("App|/Applications/App.app|com.x|100|\$encoded|||false|false|||false|false")
paginated_multi_select() {
    MOLE_SELECTION_RESULT=""
    return 0
}
interactive_review_files
IFS='|' read -r _ _ _ _ enc_related enc_system _ _ _ _ enc_diag _ keep_app <<< "\${app_details[0]}"
echo "keep_app=\$keep_app"
echo "rel_len=\${#enc_related}"
echo "sys_len=\${#enc_system}"
echo "diag_len=\${#enc_diag}"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep_app=true"* ]]
    [[ "$output" == *"rel_len=0"* ]]
    [[ "$output" == *"sys_len=0"* ]]
    [[ "$output" == *"diag_len=0"* ]]
}

@test "_recompute_uninstall_aggregates drops sudo + brew_cask entries for kept apps" {
    run bash --noprofile --norc <<EOF
$(prelude)
# Two apps:
#  A: brew cask, system files present, keep_app=false  -> sudo + brew_cask
#  B: brew cask, kept (keep_app=true), no system files -> neither
sys_a_enc="\$(enc "/Library/LaunchDaemons/com.a.plist")"
app_details=(
  "A|/Applications/A.app|com.a|100|||false|true|true|caskA||false|false"
  "B|/Applications/B.app|com.b|100|||false|true|true|caskB||false|true"
)
# Inject sys for A by rewriting row.
app_details[0]="A|/Applications/A.app|com.a|100||\$sys_a_enc|false|true|true|caskA||false|false"
sudo_apps=()
brew_cask_apps=()
_recompute_uninstall_aggregates
printf 'sudo_apps='; printf '%s ' "\${sudo_apps[@]}"; echo
printf 'brew_cask_apps='; printf '%s ' "\${brew_cask_apps[@]}"; echo
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo_apps=A "* ]]
    [[ "$output" != *"sudo_apps=A B"* ]]
    [[ "$output" == *"brew_cask_apps=A "* ]]
    [[ "$output" != *"brew_cask_apps=A B"* ]]
}

@test "_recompute_uninstall_aggregates marks needs_sudo apps when bundle still being removed" {
    run bash --noprofile --norc <<EOF
$(prelude)
# App C: not brew, no system files left, but original needs_sudo=true and keep_app=false.
# Expectation: still in sudo_apps because mole_delete on app_path will need sudo.
app_details=("C|/Applications/C.app|com.c|100|||false|true|false|||false|false")
sudo_apps=()
brew_cask_apps=()
_recompute_uninstall_aggregates
printf 'sudo_apps='; printf '%s ' "\${sudo_apps[@]}"; echo
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo_apps=C "* ]]
}

@test "confirm prompt copy advertises the R review keystroke" {
    run grep -E 'Enter.*confirm.*R.*review.*ESC.*cancel' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -eq 0 ]
}

@test "_recompute_uninstall_aggregates rebuilds total_estimated_size and size_display from current rows" {
    run bash --noprofile --norc <<EOF
$(prelude)
app_details=(
  "A|/Applications/A.app|com.a|100|||false|false|false|||false|false"
  "B|/Applications/B.app|com.b|250|||false|false|false|||false|true"
)
sudo_apps=()
brew_cask_apps=()
total_estimated_size=99999
size_display="STALE"
_recompute_uninstall_aggregates
echo "total=\$total_estimated_size"
echo "display=\$size_display"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=350"* ]]
    [[ "$output" != *"display=STALE"* ]]
}

@test "deletion success branch routes keep_app=true rows to kept_items, not success_items" {
    # shellcheck disable=SC2016 # regex pattern; literal $app_path is intentional
    run grep -nE 'kept_items\+=\("\$app_path"\)' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -eq 0 ]
    run grep -nE 'kept_count=\$\(\(kept_count \+ 1\)\)' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -eq 0 ]
}

@test "Dock cleanup invocation is gated to success_items only" {
    run grep -nE 'remove_apps_from_dock "\$\{success_items\[@\]\}"' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -eq 0 ]
    # Negative: must NOT pass kept_items into Dock removal.
    run grep -nE 'remove_apps_from_dock "\$\{kept_items' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -ne 0 ]
}

# Safety regression for tw93's launch-services bug:
# `stop_launch_services` historically deleted the plist files itself via
# `safe_remove`/`safe_sudo_remove`, which silently overrode the picker's
# selection. The function must be unload-only now -- plist deletion is owned by
# `remove_file_list`, which respects the picker's surviving paths.
@test "stop_launch_services never invokes safe_remove or safe_sudo_remove" {
    run grep -nE '^[[:space:]]*safe_(sudo_)?remove[[:space:]]' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    if [ "$status" -eq 0 ]; then
        # If any safe_remove/safe_sudo_remove appears, ensure none of them are
        # inside stop_launch_services. Easiest: extract the function body and
        # grep again.
        body=$(awk '/^stop_launch_services\(\) \{/,/^}/' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh")
        if echo "$body" | grep -nE '^[[:space:]]*safe_(sudo_)?remove[[:space:]]'; then
            return 1
        fi
    fi
}

# Safety regression for tw93 case B (kept .app + kept LaunchDaemon plist):
# `stop_launch_services` must run regardless of `keep_app` so the daemon is
# unloaded before `remove_file_list` deletes its plist. Otherwise we leave a
# zombie root daemon registered with launchd until reboot.
@test "stop_launch_services is called outside the keep_app != true gate" {
    # The unload call should appear before the keep_app gate that wraps the
    # bundle-removal block, not inside it.
    run awk '
        /^[[:space:]]*stop_launch_services / { print NR": "$0 }
        /^[[:space:]]*if \[\[ "\$keep_app" != "true" \]\]; then$/ { print NR": "$0 }
    ' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh"
    [ "$status" -eq 0 ]
    # Find the line number of the first stop_launch_services call inside
    # batch_uninstall_applications and the first keep_app gate after it. The
    # call must come BEFORE that gate (so it always runs).
    call_line=$(awk '/^[[:space:]]*stop_launch_services "\$bundle_id"/ { print NR; exit }' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh")
    [ -n "$call_line" ]
    # The keep_app gate that wraps unregister_app_bundle / remove_login_item /
    # force_kill_app starts somewhere after $call_line. We grab the first one.
    gate_line=$(awk -v start="$call_line" 'NR>start && /^[[:space:]]*if \[\[ "\$keep_app" != "true" \]\]; then$/ { print NR; exit }' "${BATS_TEST_DIRNAME}/../lib/uninstall/batch.sh")
    [ -n "$gate_line" ]
    [ "$call_line" -lt "$gate_line" ]
}
