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

run_case() {
    local units="$1"
    local expected="$2"
    local tmpdir helper

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "list-unit-files --type=service --no-legend")
        printf '%s\n' "$MOCK_UNITS"
        ;;
    "restart ssh")
        printf 'restart ssh\n' >> "$MOCK_LOG"
        ;;
    "restart sshd")
        printf 'restart sshd\n' >> "$MOCK_LOG"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpdir/systemctl"

    export PATH="$tmpdir:$PATH"
    export MOCK_UNITS="$units"
    export MOCK_LOG="$tmpdir/log"
    : > "$MOCK_LOG"

    helper="$(extract_helper get_ssh_service_name)"
    helper+=$'\n'
    helper+="$(extract_helper restart_ssh_service)"
    error() { printf 'ERROR: %s\n' "$*" >&2; }
    eval "$helper"
    restart_ssh_service

    grep -qx "$expected" "$MOCK_LOG"
}

run_case "ssh.service enabled" "restart ssh"
run_case "sshd.service enabled" "restart sshd"

printf 'PASS\n'
