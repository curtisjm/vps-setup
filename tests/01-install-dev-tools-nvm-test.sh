#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/01-install-dev-tools.sh"

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

with_mock_infocmp() {
    local tmpdir="$1"

    cat > "$tmpdir/infocmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "xterm-ghostty" ]]; then
    exit 1
fi

exit 0
EOF
    chmod +x "$tmpdir/infocmp"
}

test_run_nvm_safely_disables_nounset_for_nvm_calls() {
    load_helpers run_nvm_safely

    log() { :; }
    warn() { :; }

    nvm() {
        printf '%s\n' "$PROVIDED_VERSION" >/dev/null
        [[ "$1" == "alias" ]]
    }

    run_nvm_safely alias default lts/*
}

test_run_nvm_safely_uses_known_term_temporarily() {
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_infocmp "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export TERM="xterm-ghostty"
    export MOCK_LOG="$tmpdir/log"
    : > "$MOCK_LOG"

    load_helpers run_nvm_safely

    log() { :; }
    warn() { :; }

    nvm() {
        printf '%s\n' "${TERM:-}" >> "$MOCK_LOG"
        return 0
    }

    run_nvm_safely install --lts

    grep -qx 'xterm-256color' "$MOCK_LOG"
    [[ "$TERM" == "xterm-ghostty" ]]
}

test_run_nvm_safely_disables_nounset_for_nvm_calls
test_run_nvm_safely_uses_known_term_temporarily

printf 'PASS\n'
