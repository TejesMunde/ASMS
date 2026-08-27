#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: generate_audit.sh
# Version: 2.0.0
#
# Generates auditd rules recording student execution of sensitive commands.
#
# Rules match on the students GID, not on individual UIDs.
#
# Why: students are created with STUDENT_GROUP as their PRIMARY group, so a
# gid match covers exactly the student population and nothing else. Faculty
# (whose primary group is their own), admin and service accounts are excluded
# by construction.
#
# The alternative -- one rule per student UID per command per architecture --
# is what the scaffold did. It produces about twenty rules per enrolled
# student: 6,000 rules at 300 students, walked by the kernel on every
# matching syscall. It also had to be regenerated on every roster change to
# stay correct, where a gid rule stays correct automatically.
#
# Known limitation: a student who acquires a different effective GID is not
# matched. ASMS never adds students to another group; if you do so manually,
# extend the filter here to match.
#
# Usage:
#   generate_audit.sh              interactive menu
#   generate_audit.sh --generate   write and load rules (used by other modules)
#   generate_audit.sh --show       print the current rules
#   generate_audit.sh --remove     remove ASMS audit rules
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

TMP_RULES=""
BACKUP_RULES=""

cleanup() {
    [[ -n "$TMP_RULES"    && -f "$TMP_RULES"    ]] && rm -f "$TMP_RULES"
    [[ -n "$BACKUP_RULES" && -f "$BACKUP_RULES" ]] && rm -f "$BACKUP_RULES"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------

student_gid() {
    getent group "$STUDENT_GROUP" | cut -d: -f3
}

audit_key_for() {
    printf '%s_%s' "$AUDIT_KEY_PREFIX" "$1"
}

# Paths are resolved rather than assumed. The scaffold hardcoded /usr/bin,
# which silently skipped any command installed elsewhere and produced no
# rule and no warning for it.
resolve_command() {
    command -v "$1" 2>/dev/null
}

build_rules() {
    local gid command path key
    local resolved=0 skipped=()

    gid="$(student_gid)"

    [[ -n "$gid" ]] || {
        error "Student group '$STUDENT_GROUP' does not exist."
        return 1
    }

    {
        echo "## ASMS student command audit rules"
        echo "## Generated: $(timestamp)"
        echo "## Do not edit by hand; regenerate with generate_audit.sh."
        echo "##"
        echo "## Matches the '${STUDENT_GROUP}' group (gid ${gid}), which is every"
        echo "## student's primary group. Faculty and service accounts are excluded."
        echo

        for command in $AUDIT_COMMANDS; do
            path="$(resolve_command "$command")" || true

            if [[ -z "$path" ]]; then
                # No rule for a command that is not installed: auditctl would
                # reject the whole file over one bad path.
                skipped+=("$command")
                continue
            fi

            key="$(audit_key_for "$command")"
            resolved=$((resolved + 1))

            printf '## %s\n' "$path"
            printf -- '-a always,exit -F arch=b64 -S execve -F gid=%s -F exe=%s -F key=%s\n' \
                "$gid" "$path" "$key"

            # 32-bit syscalls on a 64-bit kernel are a separate rule; without
            # it a 32-bit binary would execute unrecorded.
            if [[ "$(uname -m)" == "x86_64" ]]; then
                printf -- '-a always,exit -F arch=b32 -S execve -F gid=%s -F exe=%s -F key=%s\n' \
                    "$gid" "$path" "$key"
            fi

            echo
        done
    } > "$TMP_RULES"

    if ((${#skipped[@]} > 0)); then
        warn "Not installed, so not audited: ${skipped[*]}"

        if [[ " ${skipped[*]} " == *" submit "* ]]; then
            warn "'submit' is missing -- run install.sh to build and install it."
        fi
    fi

    info "Audit rules generated for ${resolved} command(s), gid ${gid}."
}

install_rules() {
    if [[ -f "$AUDIT_RULE_FILE" ]]; then
        BACKUP_RULES="$(mktemp)"
        cp -a "$AUDIT_RULE_FILE" "$BACKUP_RULES"
    fi

    install -d -o root -g root -m 0750 "$(dirname "$AUDIT_RULE_FILE")"
    install -o root -g root -m 0640 "$TMP_RULES" "$AUDIT_RULE_FILE"
}

restore_rules() {
    if [[ -n "$BACKUP_RULES" && -f "$BACKUP_RULES" ]]; then
        cp -a "$BACKUP_RULES" "$AUDIT_RULE_FILE"
        warn "Previous audit rules restored."
    else
        rm -f "$AUDIT_RULE_FILE"
        warn "Generated audit rules removed."
    fi

    augenrules --load >/dev/null 2>&1 || true
}

load_rules() {
    augenrules --load || {
        error "augenrules failed to load the generated rules."
        return 1
    }
}

# Confirms the rules are actually live, not merely written to a file. A
# rule file that auditd rejected leaves no trace unless it is checked for.
verify_live_rules() {
    local live command key missing=()

    live="$(auditctl -l 2>/dev/null || true)"

    for command in $AUDIT_COMMANDS; do
        resolve_command "$command" >/dev/null || continue

        key="$(audit_key_for "$command")"

        grep -Fq "key=${key}" <<< "$live" || missing+=("$key")
    done

    if ((${#missing[@]} > 0)); then
        error "Rules were loaded but these keys are not live: ${missing[*]}"
        return 1
    fi

    return 0
}

generate() {
    header "Generate Student Audit Rules"

    cmd_exists auditctl   || die "auditctl not found. Install auditd first."
    cmd_exists augenrules || die "augenrules not found. Install auditd first."

    TMP_RULES="$(mktemp)"

    build_rules || return 1
    install_rules

    if ! load_rules; then
        restore_rules
        log_action "GENERATE_AUDIT" "$AUDIT_RULE_FILE" "FAILED_LOAD"
        return 1
    fi

    if ! verify_live_rules; then
        log_action "GENERATE_AUDIT" "$AUDIT_RULE_FILE" "WARNING_VERIFY"
        warn "Check 'auditctl -l' and the auditd service state."
        return 1
    fi

    show_summary
    success "Student audit rules generated and loaded."
    log_action "GENERATE_AUDIT" "$AUDIT_RULE_FILE" "SUCCESS"
}

remove_rules() {
    header "Remove Student Audit Rules"

    [[ -f "$AUDIT_RULE_FILE" ]] || {
        info "No ASMS audit rules are installed."
        return 0
    }

    confirm "Remove ASMS audit rules from ${AUDIT_RULE_FILE}?" || {
        info "Cancelled."
        return 0
    }

    rm -f "$AUDIT_RULE_FILE"

    cmd_exists augenrules && augenrules --load >/dev/null 2>&1 || true

    success "ASMS audit rules removed."
    log_action "REMOVE_AUDIT" "$AUDIT_RULE_FILE" "SUCCESS"
}

show_rules() {
    header "Current ASMS Audit Rules"

    if [[ -f "$AUDIT_RULE_FILE" ]]; then
        echo "Rule file: $AUDIT_RULE_FILE"
        echo
        grep -v '^\s*$' "$AUDIT_RULE_FILE" | sed 's/^/  /'
    else
        warn "No rule file at $AUDIT_RULE_FILE"
    fi

    echo
    echo "Live rules matching '${AUDIT_KEY_PREFIX}':"
    echo

    if cmd_exists auditctl; then
        auditctl -l 2>/dev/null | grep -F "$AUDIT_KEY_PREFIX" | sed 's/^/  /' ||
            warn "No live ${AUDIT_KEY_PREFIX} rules."
    else
        warn "auditctl is not installed."
    fi
}

show_summary() {
    local command keys=()

    for command in $AUDIT_COMMANDS; do
        resolve_command "$command" >/dev/null && keys+=("$(audit_key_for "$command")")
    done

    echo
    printf '  %-24s %s\n' "Rule file"       "$AUDIT_RULE_FILE"
    printf '  %-24s %s (gid %s)\n' "Audited group" "$STUDENT_GROUP" "$(student_gid)"
    printf '  %-24s %s\n' "Students covered" "$(count_users_in_group "$STUDENT_GROUP")"
    printf '  %-24s %s\n' "Commands audited" "${#keys[@]}"
    echo
    echo "  Search recorded activity with:"
    printf '    ausearch -k %s\n' "${keys[0]:-${AUDIT_KEY_PREFIX}_rm}"
    echo
}

audit_menu() {
    header "Student Audit Rules"

    echo "1. Generate and load audit rules"
    echo "2. Show current rules"
    echo "3. Remove ASMS audit rules"
    echo "4. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    case "$choice" in
        1) generate ;;
        2) show_rules ;;
        3) remove_rules ;;
        4) return 0 ;;
        *) die "Invalid choice." ;;
    esac
}

usage() {
    cat <<EOF
Usage: generate_audit.sh [option]

  --generate   Generate and load student audit rules
  --show       Show the current rule file and live rules
  --remove     Remove ASMS audit rules
  -h, --help   Show this help

With no option an interactive menu is shown.
EOF
}

main() {
    case "${1:-}" in
        --generate) generate ;;
        --show)     show_rules ;;
        --remove)   remove_rules ;;
        -h|--help)  usage ;;
        "")         audit_menu ;;
        *)          usage >&2; die "Unknown option: $1" ;;
    esac
}

main "$@"
