#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: remove_faculty.sh
# Version: 2.0.0
#
# Removes faculty accounts.
#
# Faculty do not own submission archives, so nothing under SUBMISSION_ROOT is
# touched here. Their read access came from the g:<faculty>:rX ACL on each
# student archive, which stops applying the moment the account leaves the
# group -- the ACLs themselves need no cleanup.
#
# Usage:
#   remove_faculty.sh                    interactive menu
#   remove_faculty.sh --users smith
#   remove_faculty.sh --all
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

REMOVED=0
FAILED=0

remove_credential_record() {
    local username="$1"
    local tmp

    [[ -f "$FACULTY_CREDENTIALS" ]] || return 0

    tmp="$(mktemp)"

    awk -F',' -v u="$username" '
        NR == 1 { print; next }
        $1 != u { print }
    ' "$FACULTY_CREDENTIALS" > "$tmp"

    cat "$tmp" > "$FACULTY_CREDENTIALS"
    rm -f "$tmp"

    chmod "$CREDENTIAL_FILE_MODE" "$FACULTY_CREDENTIALS"
}

remove_faculty_account() {
    local username="$1"

    if is_protected_account "$username"; then
        error "Refusing to remove protected account: $username"
        log_action "REMOVE_FACULTY" "$username" "REFUSED_PROTECTED"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if ! user_exists "$username"; then
        warn "Account does not exist: $username"
        return 0
    fi

    if ! is_faculty_user "$username"; then
        error "$username is not a member of $FACULTY_GROUP; refusing removal."
        log_action "REMOVE_FACULTY" "$username" "REFUSED_NOT_FACULTY"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # A student account should never be removable through the faculty module,
    # whatever groups it has picked up: student removal has to unmount the
    # submission view first, and this module does not do that.
    if is_student_user "$username"; then
        error "$username is also a student account."
        error "Use Remove Students, which unmounts the submission view first."
        log_action "REMOVE_FACULTY" "$username" "REFUSED_IS_STUDENT"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if ! userdel -r "$username" 2>/dev/null; then
        if user_exists "$username"; then
            error "Failed to remove faculty account: $username"
            log_action "REMOVE_FACULTY" "$username" "FAILED_USERDEL"
            FAILED=$((FAILED + 1))
            return 1
        fi

        warn "$username: account removed, but some files may remain in $(student_home_path "$username")"
    fi

    remove_credential_record "$username"

    log_action "REMOVE_FACULTY" "$username" "SUCCESS"
    success "Removed faculty: $username"
    REMOVED=$((REMOVED + 1))
}

remove_list() {
    local username

    IFS=',' read -ra requested <<< "$1"

    for username in "${requested[@]}"; do
        username="${username//[[:space:]]/}"
        [[ -n "$username" ]] || continue

        remove_faculty_account "$username" || true
    done
}

remove_all() {
    local faculty username

    mapfile -t faculty < <(get_faculty_users)

    if ((${#faculty[@]} == 0)); then
        info "No faculty accounts found."
        return 0
    fi

    echo
    echo "Faculty accounts to be removed:"
    printf '  %s\n' "${faculty[@]}"
    echo

    confirm "Remove ALL ${#faculty[@]} faculty account(s) and their home directories?" || {
        info "Cancelled."
        return 0
    }

    for username in "${faculty[@]}"; do
        remove_faculty_account "$username" || true
    done
}

remove_menu() {
    header "Faculty Removal"

    echo "1. Remove selected faculty"
    echo "2. Remove all faculty"
    echo "3. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    case "$choice" in
        1)
            local input
            input="$(prompt_value "Faculty IDs (comma separated)")"
            [[ -n "$input" ]] || die "No faculty IDs supplied."

            confirm "Remove these accounts and their home directories?" || {
                info "Cancelled."
                return 0
            }

            remove_list "$input"
            ;;
        2) remove_all ;;
        3) return 0 ;;
        *) die "Invalid choice." ;;
    esac
}

show_summary() {
    echo
    header "Faculty Removal Complete"

    printf '  %-24s %s\n' "Removed"   "$REMOVED"
    printf '  %-24s %s\n' "Failed"    "$FAILED"
    printf '  %-24s %s\n' "Remaining" "$(count_users_in_group "$FACULTY_GROUP")"
    echo
}

usage() {
    cat <<EOF
Usage: remove_faculty.sh [option]

  --users a,b,c    Remove the named faculty accounts
  --all            Remove every faculty account
  -h, --help       Show this help

With no option an interactive menu is shown.
EOF
}

main() {
    require_command userdel

    group_exists "$FACULTY_GROUP" ||
        die "Faculty group '$FACULTY_GROUP' does not exist."

    case "${1:-}" in
        --users)
            [[ -n "${2:-}" ]] || die "--users requires a comma-separated list."
            remove_list "$2"
            ;;
        --all)     remove_all ;;
        -h|--help) usage; return 0 ;;
        "")        remove_menu ;;
        *)         usage >&2; die "Unknown option: $1" ;;
    esac

    show_summary

    ((FAILED == 0))
}

main "$@"
