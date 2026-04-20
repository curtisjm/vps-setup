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

with_mock_brew() {
    local tmpdir="$1"

    cat > "$tmpdir/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "list --formula flock")
        [[ "${MOCK_FLOCK_INSTALLED:-no}" == "yes" ]]
        ;;
    "unlink flock")
        printf 'unlink flock\n' >> "$MOCK_LOG"
        [[ "${MOCK_UNLINK_EXIT:-0}" -eq 0 ]]
        ;;
    "install gastownhall/gascity/gascity")
        printf 'install gascity\n' >> "$MOCK_LOG"
        exit "${MOCK_INSTALL_EXIT:-0}"
        ;;
    "link flock")
        printf 'link flock\n' >> "$MOCK_LOG"
        exit "${MOCK_LINK_EXIT:-0}"
        ;;
    *)
        printf 'unexpected brew invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpdir/brew"
}

run_gascity_case() {
    local flock_installed="$1"
    local install_exit="$2"
    local expected_log="$3"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN
    with_mock_brew "$tmpdir"

    export PATH="$tmpdir:$PATH"
    export MOCK_LOG="$tmpdir/log"
    export MOCK_FLOCK_INSTALLED="$flock_installed"
    export MOCK_INSTALL_EXIT="$install_exit"
    export MOCK_UNLINK_EXIT=0
    export MOCK_LINK_EXIT=0
    : > "$MOCK_LOG"

    load_helpers install_gascity_with_brew_conflict_workaround

    log() { :; }
    ok() { :; }
    warn() { :; }

    if [[ "$install_exit" == "0" ]]; then
        install_gascity_with_brew_conflict_workaround
    else
        ! install_gascity_with_brew_conflict_workaround
    fi

    printf '%s\n' "$expected_log" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qx "$line" "$MOCK_LOG"
    done
}

test_gascity_install_unlinks_and_relinks_brew_flock() {
    run_gascity_case yes 0 $'unlink flock\ninstall gascity\nlink flock'
}

test_gascity_install_skips_flock_workaround_when_not_installed() {
    run_gascity_case no 0 $'install gascity'
}

test_gascity_install_relinks_flock_after_failed_install() {
    run_gascity_case yes 1 $'unlink flock\ninstall gascity\nlink flock'
}

test_run_nvm_safely_disables_nounset_for_nvm_calls
test_run_nvm_safely_uses_known_term_temporarily
test_gascity_install_unlinks_and_relinks_brew_flock
test_gascity_install_skips_flock_workaround_when_not_installed
test_gascity_install_relinks_flock_after_failed_install

printf 'PASS\n'
