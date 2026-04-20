#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/00-harden.sh"

extract_helper() {
    local name="$1"
    awk -v name="$name" '
        $0 ~ ("^" name "\\(\\) \\{") { capture = 1 }
        capture { print }
        $0 ~ ("^# end " name "$") { capture = 0 }
    ' "$SCRIPT_PATH" | sed '$d'
}

load_helpers() {
    local helper
    for helper in "$@"; do
        eval "$(extract_helper "$helper")"
    done
}

with_mock_ufw() {
    local tmpdir="$1"

    cat > "$tmpdir/ufw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "status")
        printf '%s\n' "$MOCK_UFW_STATUS"
        ;;
    "allow 6152/tcp comment SSH")
        printf 'allow 6152/tcp\n' >> "$MOCK_LOG"
        ;;
    "--force delete allow 61525/tcp")
        printf 'delete 61525/tcp\n' >> "$MOCK_LOG"
        ;;
    *)
        printf 'unexpected ufw invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpdir/ufw"
}

with_mock_systemctl() {
    local tmpdir="$1"

    cat > "$tmpdir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "list-unit-files --type=service --no-legend")
        printf '%s\n' "$MOCK_UNITS"
        ;;
    "is-active --quiet ssh.socket")
        [[ "${MOCK_SSH_SOCKET_ACTIVE:-no}" == "yes" ]]
        ;;
    "cat ssh.socket")
        cat <<EOF2
[Socket]
ListenStream=${MOCK_SSH_SOCKET_LISTEN_STREAM:-22}
EOF2
        ;;
    "disable --now ssh.socket")
        printf 'disable --now ssh.socket\n' >> "$MOCK_LOG"
        ;;
    "enable --now ssh")
        printf 'enable --now ssh\n' >> "$MOCK_LOG"
        ;;
    "enable --now sshd")
        printf 'enable --now sshd\n' >> "$MOCK_LOG"
        ;;
    "is-active --quiet ssh")
        [[ "${MOCK_SSH_SERVICE_ACTIVE:-yes}" == "yes" ]]
        ;;
    "is-active --quiet sshd")
        [[ "${MOCK_SSHD_SERVICE_ACTIVE:-yes}" == "yes" ]]
        ;;
    *)
        printf 'unexpected systemctl invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpdir/systemctl"
}

run_firewall_transition_case() {
    local ufw_status="$1"
    local expect_allow="$2"
    local expect_delete="$3"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_ufw "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export MOCK_UFW_STATUS="$ufw_status"
    export MOCK_LOG="$tmpdir/log"
    : > "$MOCK_LOG"

    log() { :; }
    ok() { :; }
    warn() { :; }

    load_helpers ufw_is_active prepare_ufw_for_ssh_port_change remove_old_ufw_rule_for_ssh_port_change

    prepare_ufw_for_ssh_port_change 61525 6152
    remove_old_ufw_rule_for_ssh_port_change 61525 6152

    if [[ "$expect_allow" == "yes" ]]; then
        grep -qx 'allow 6152/tcp' "$MOCK_LOG"
    else
        ! grep -q 'allow 6152/tcp' "$MOCK_LOG"
    fi

    if [[ "$expect_delete" == "yes" ]]; then
        grep -qx 'delete 61525/tcp' "$MOCK_LOG"
    else
        ! grep -q 'delete 61525/tcp' "$MOCK_LOG"
    fi
}

test_build_ssh_login_command() {
    load_helpers build_ssh_login_command

    [[ "$(build_ssh_login_command curtis 85.239.244.245 22)" == "ssh curtis@85.239.244.245" ]]
    [[ "$(build_ssh_login_command curtis 85.239.244.245 6152)" == "ssh -p 6152 curtis@85.239.244.245" ]]
}

test_socket_hosts_report_live_socket_port() {
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_systemctl "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export MOCK_SSH_SOCKET_ACTIVE=yes
    export MOCK_SSH_SOCKET_LISTEN_STREAM=61525

    load_helpers ssh_socket_is_active get_ssh_socket_port get_current_ssh_port

    [[ "$(get_current_ssh_port)" == "61525" ]]
}

run_socket_migration_case() {
    local current_port="$1"
    local desired_port="$2"
    local expect_actions="$3"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_systemctl "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export MOCK_UNITS="ssh.service enabled"
    export MOCK_SSH_SOCKET_ACTIVE=yes
    export MOCK_LOG="$tmpdir/log"
    : > "$MOCK_LOG"

    log() { :; }
    ok() { :; }
    error() { printf 'ERROR: %s\n' "$*" >&2; }

    load_helpers get_ssh_service_name ssh_socket_is_active prepare_ssh_activation_for_port_change

    prepare_ssh_activation_for_port_change "$current_port" "$desired_port"

    if [[ "$expect_actions" == "yes" ]]; then
        grep -qx 'disable --now ssh.socket' "$MOCK_LOG"
        grep -qx 'enable --now ssh' "$MOCK_LOG"
    else
        [[ ! -s "$MOCK_LOG" ]]
    fi
}

test_socket_hosts_only_migrate_when_port_changes() {
    run_socket_migration_case 22 22 no
    run_socket_migration_case 22 6152 yes
}

test_active_ufw_keeps_old_port_until_cleanup() {
    run_firewall_transition_case $'Status: active' yes yes
}

test_inactive_ufw_skips_transition_rules() {
    run_firewall_transition_case $'Status: inactive' no no
}

test_build_ssh_login_command
test_socket_hosts_report_live_socket_port
test_socket_hosts_only_migrate_when_port_changes
test_active_ufw_keeps_old_port_until_cleanup
test_inactive_ufw_skips_transition_rules

printf 'PASS\n'
