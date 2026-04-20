#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_02="$ROOT_DIR/02-setup-git.sh"
SCRIPT_03="$ROOT_DIR/03-install-dolt.sh"
SCRIPT_04="$ROOT_DIR/04-contabo-diagnostics.sh"
SCRIPT_05="$ROOT_DIR/05-export-from-laptop.sh"
SCRIPT_06="$ROOT_DIR/06-migrate-gastown.sh"

extract_helper() {
    local script="$1"
    local name="$2"

    awk -v name="$name" '
        $0 ~ ("^" name "\\(\\) \\{") { capture = 1 }
        capture { print }
        $0 ~ ("^# end " name "$") { capture = 0 }
    ' "$script" | sed '$d'
}

load_helpers() {
    local script="$1"
    shift

    local helper
    for helper in "$@"; do
        eval "$(extract_helper "$script" "$helper")"
    done
}

test_ssh_config_has_exact_host() {
    local tmpdir config

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    config="$tmpdir/config"

    load_helpers "$SCRIPT_02" ssh_config_has_exact_host

    cat > "$config" <<'EOF'
Host github.com-work
    HostName github.com
EOF
    ! ssh_config_has_exact_host "$config" github.com

    cat > "$config" <<'EOF'
Host github.com github-alias
    HostName github.com
EOF
    ssh_config_has_exact_host "$config" github.com
}

test_ensure_local_bin_dir() {
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    export HOME="$tmpdir/home"

    load_helpers "$SCRIPT_03" ensure_local_bin_dir

    [[ ! -d "$HOME/.local/bin" ]]
    ensure_local_bin_dir
    [[ -d "$HOME/.local/bin" ]]
}

with_mock_ping() {
    local tmpdir="$1"

    cat > "$tmpdir/ping" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${MOCK_PING_MODE:-success}" == "fail" ]]; then
    exit 2
fi

cat <<EOF2
PING $2 ($2): 56 data bytes

--- $2 ping statistics ---
5 packets transmitted, 5 packets received, ${MOCK_PACKET_LOSS:-0.0}% packet loss
round-trip min/avg/max/stddev = 10.000/${MOCK_LATENCY:-12.345}/15.000/1.000 ms
EOF2
EOF
    chmod +x "$tmpdir/ping"
}

test_capture_ping_helpers() {
    local tmpdir latency loss

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_ping "$tmpdir"

    export PATH="$tmpdir:$PATH"
    load_helpers "$SCRIPT_04" capture_ping_latency capture_ping_packet_loss

    export MOCK_PING_MODE=fail
    latency="$(capture_ping_latency api.openai.com)"
    [[ -z "$latency" ]]
    loss="$(capture_ping_packet_loss 1.1.1.1)"
    [[ -z "$loss" ]]

    export MOCK_PING_MODE=success
    export MOCK_LATENCY=23.456
    export MOCK_PACKET_LOSS=0
    latency="$(capture_ping_latency api.openai.com)"
    [[ "$latency" == "23.456" ]]
    loss="$(capture_ping_packet_loss 1.1.1.1)"
    [[ "$loss" == "0" ]]
}

test_export_helpers() {
    local tmpdir remote repo

    load_helpers "$SCRIPT_05" build_restore_command git_repo_has_uncommitted_changes git_repo_is_ahead_of_upstream

    [[ "$(build_restore_command 20260420-123000 yes)" == "./06-migrate-gastown.sh ~/dolt-data-20260420-123000.tar.gz ~/claude-20260420-123000.tar.gz" ]]
    [[ "$(build_restore_command 20260420-123000 no)" == "./06-migrate-gastown.sh ~/dolt-data-20260420-123000.tar.gz" ]]

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    remote="$tmpdir/remote.git"
    repo="$tmpdir/repo"

    git init --bare "$remote" >/dev/null 2>&1
    git clone "$remote" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.name "Curtis"
    git -C "$repo" config user.email "curtis@example.com"

    printf 'hello\n' > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "initial" >/dev/null 2>&1
    git -C "$repo" push -u origin HEAD >/dev/null 2>&1

    ! git_repo_has_uncommitted_changes "$repo"
    ! git_repo_is_ahead_of_upstream "$repo"

    printf 'local drift\n' >> "$repo/file.txt"
    git_repo_has_uncommitted_changes "$repo"

    git -C "$repo" add file.txt
    git -C "$repo" commit -m "ahead" >/dev/null 2>&1
    git_repo_is_ahead_of_upstream "$repo"
}

with_mock_migrate_commands() {
    local tmpdir="$1"

    cat > "$tmpdir/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "-C "*)
        if [[ "$*" == *"pull --recurse-submodules" ]]; then
            printf 'git pull\n' >> "$MOCK_LOG"
            exit "${MOCK_GIT_PULL_EXIT:-0}"
        fi
        ;;
esac

printf 'unexpected git invocation: %s\n' "$*" >&2
exit 1
EOF
    chmod +x "$tmpdir/git"

    cat > "$tmpdir/gt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
    doctor)
        printf 'gt doctor\n' >> "$MOCK_LOG"
        exit "${MOCK_GT_DOCTOR_EXIT:-0}"
        ;;
    *)
        printf 'unexpected gt invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpdir/gt"
}

test_migrate_fail_fast_helpers() {
    local tmpdir repo

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    repo="$tmpdir/repo"
    mkdir -p "$repo/.git"
    with_mock_migrate_commands "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export MOCK_LOG="$tmpdir/log"
    : > "$MOCK_LOG"

    log() { :; }
    ok() { :; }
    warn() { :; }
    error() { :; }

    load_helpers "$SCRIPT_06" refresh_gt_checkout run_gt_doctor_or_fail

    export MOCK_GIT_PULL_EXIT=1
    ! refresh_gt_checkout "$repo" git@github.com:curtisjm/gt.git

    export MOCK_GIT_PULL_EXIT=0
    refresh_gt_checkout "$repo" git@github.com:curtisjm/gt.git

    export MOCK_GT_DOCTOR_EXIT=1
    ! run_gt_doctor_or_fail

    export MOCK_GT_DOCTOR_EXIT=0
    run_gt_doctor_or_fail
}

test_ssh_config_has_exact_host
test_ensure_local_bin_dir
test_capture_ping_helpers
test_export_helpers
test_migrate_fail_fast_helpers

printf 'PASS\n'
