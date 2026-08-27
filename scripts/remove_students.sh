#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: remove_students.sh
# Version: 2.0.0
#
# The single implementation of student removal. reset_semester.sh calls this
# module rather than carrying its own copy.
#
# Order of operations per student:
#   1. unmount the submission view and drop its fstab entry
#   2. optionally delete the authoritative archive
#   3. remove the credentials record
#   4. userdel -r
#
# Step 1 must succeed before step 4. `userdel -r` deletes the home directory,
# and if ~/submissions is still mounted at that moment it deletes THROUGH the
# bind mount into the authoritative archive -- destroying submitted work that
# the operation was supposed to preserve. If the view cannot be unmounted,
# this module refuses to remove the account.
#
# Usage:
#   remove_students.sh                                  interactive menu
#   remove_students.sh --users a,b --keep-archive
#   remove_students.sh --all --delete-archive
#   remove_students.sh --demo --delete-archive
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

load_config

# shellcheck source=configure_mounts.sh
source "${ASMS_MODULE_DIR}/configure_mounts.sh"

REMOVED=0
FAILED=0

# Real outcomes, not the archive-action flag. show_summary() reports these
# instead of inferring "deleted" from DELETE_ARCHIVE alone -- that flag only
# says what was requested, not what happened. A nonexistent or otherwise
# invalid account must never move any of these off zero.
ARCHIVES_DELETED=0
ARCHIVES_KEPT=0
ARCHIVES_NOT_FOUND=0
ARCHIVE_DELETE_FAILED=0

# Set when a selection resolved to zero valid accounts (everything requested
# was nonexistent, protected, malformed, or not a student). Distinct from
# FAILED: nothing was attempted, so nothing failed, but it was not a no-op
# success either -- main() folds this into the exit status.
NOTHING_TO_REMOVE=0

# Populated by resolve_removal_targets(); declared here so both arrays exist
# even before the first call.
VALID_TARGETS=()
INVALID_TARGETS=()

# Deleting a student's submitted work is never the default. The caller must
# say which it wants; there is no implicit answer.
DELETE_ARCHIVE=""

# ---------------------------------------------------------------------------

is_demo_account() {
    [[ "$1" =~ $DEMO_ACCOUNT_PATTERN ]]
}

# True when the roster exists and this account is not in it. The roster is
# ground truth for who is a real student; an account outside the pattern
# provision_students.sh --demo happens to use (e.g. hand-provisioned via
# "Enter usernames manually") is still unambiguously a test account if it
# is not on the class list, whatever it was named. Returns false, not an
# error, when there is no roster to check against -- callers then rely on
# is_demo_account alone, exactly as before this existed.
is_off_roster_account() {
    local username="$1"

    [[ -f "$STUDENT_ROSTER_CSV" ]] || return 1

    ! awk -F',' -v u="$username" 'NR > 1 && $1 == u { found = 1 } END { exit !found }' \
        "$STUDENT_ROSTER_CSV"
}

remove_credential_record() {
    local username="$1"
    local tmp

    [[ -f "$STUDENT_CREDENTIALS" ]] || return 0

    tmp="$(mktemp)"

    awk -F',' -v u="$username" '
        NR == 1 { print; next }
        $1 != u { print }
    ' "$STUDENT_CREDENTIALS" > "$tmp"

    cat "$tmp" > "$STUDENT_CREDENTIALS"
    rm -f "$tmp"

    chmod "$CREDENTIAL_FILE_MODE" "$STUDENT_CREDENTIALS"
}

remove_archive() {
    local username="$1"
    local archive
    archive="$(student_archive_path "$username")"

    # No archive to delete is not a failure, and it must not be counted as a
    # deletion either -- the caller asked for the account's work to be
    # removed, and there was none, so nothing happened.
    if [[ ! -e "$archive" ]]; then
        ARCHIVES_NOT_FOUND=$((ARCHIVES_NOT_FOUND + 1))
        return 0
    fi

    # --one-file-system stops the delete at a filesystem boundary, so a stray
    # mount underneath the archive cannot pull the recursion somewhere else.
    rm -rf --one-file-system -- "$archive"

    if [[ -e "$archive" ]]; then
        error "Failed to remove archive: $archive"
        log_action "REMOVE_ARCHIVE" "$username" "FAILED"
        ARCHIVE_DELETE_FAILED=$((ARCHIVE_DELETE_FAILED + 1))
        return 1
    fi

    log_action "REMOVE_ARCHIVE" "$username" "SUCCESS"
    ARCHIVES_DELETED=$((ARCHIVES_DELETED + 1))
}

remove_student_account() {
    local username="$1"

    if is_protected_account "$username"; then
        error "Refusing to remove protected account: $username"
        log_action "REMOVE_STUDENT" "$username" "REFUSED_PROTECTED"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if ! is_valid_username_format "$username"; then
        error "Invalid username: '$username'"
        log_action "REMOVE_STUDENT" "$username" "REFUSED_INVALID_NAME"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if ! user_exists "$username"; then
        warn "Account does not exist: $username"
        return 0
    fi

    if ! is_student_user "$username"; then
        error "$username is not a student account; refusing removal."
        log_action "REMOVE_STUDENT" "$username" "REFUSED_NOT_STUDENT"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # The data-loss guard. Nothing below this point runs unless the bind
    # mount is definitely gone.
    if ! deconfigure_mount "$username"; then
        error "$username: submission view could not be unmounted."
        error "Refusing to remove the account: 'userdel -r' would delete"
        error "through the mount and destroy the submission archive."
        error "Check for open files:  fuser -vm $(student_mount_path "$username")"
        log_action "REMOVE_STUDENT" "$username" "REFUSED_MOUNT_ACTIVE"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if mountpoint -q "$(student_mount_path "$username")" 2>/dev/null; then
        error "$username: mount still present after unmount; refusing removal."
        log_action "REMOVE_STUDENT" "$username" "REFUSED_MOUNT_STILL_PRESENT"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [[ "$DELETE_ARCHIVE" == "1" ]]; then
        remove_archive "$username" || { FAILED=$((FAILED + 1)); return 1; }
    else
        ARCHIVES_KEPT=$((ARCHIVES_KEPT + 1))
        info "$username: submission archive kept at $(student_archive_path "$username")"
    fi

    remove_credential_record "$username"

    if ! userdel -r "$username" 2>/dev/null; then
        # userdel exits non-zero when the home directory was already gone,
        # which is not a failure to remove the account. Confirm directly.
        if user_exists "$username"; then
            error "Failed to remove account: $username"
            log_action "REMOVE_STUDENT" "$username" "FAILED_USERDEL"
            FAILED=$((FAILED + 1))
            return 1
        fi

        warn "$username: account removed, but some files may remain in $(student_home_path "$username")"
    fi

    log_action "REMOVE_STUDENT" "$username" "SUCCESS"
    success "Removed student: $username"
    REMOVED=$((REMOVED + 1))
}

# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------
#
# Read-only: performs no removal and asks nothing. Splits a comma-separated
# list of requested IDs into VALID_TARGETS (exist, are students, well-formed,
# not protected) and INVALID_TARGETS (everything else, with a reason).
#
# This exists so a destructive confirmation prompt is never shown for input
# that resolves to nothing -- the bug this module had: an administrator
# would be asked "Remove these accounts?" and told archives would be
# deleted, all before the script had checked whether the account existed at
# all. remove_student_account() still repeats every one of these checks
# immediately before it acts; this function only decides what to show and
# confirm, never what to trust at the point of removal.
resolve_removal_targets() {
    local input="$1"
    local username

    VALID_TARGETS=()
    INVALID_TARGETS=()

    IFS=',' read -ra requested <<< "$input"

    for username in "${requested[@]}"; do
        username="${username//[[:space:]]/}"
        [[ -n "$username" ]] || continue

        if is_protected_account "$username"; then
            INVALID_TARGETS+=("${username} (protected account)")
            log_action "REMOVE_STUDENT" "$username" "REFUSED_PROTECTED"
            continue
        fi

        if ! is_valid_username_format "$username"; then
            INVALID_TARGETS+=("${username} (invalid username)")
            log_action "REMOVE_STUDENT" "$username" "REFUSED_INVALID_NAME"
            continue
        fi

        if ! user_exists "$username"; then
            INVALID_TARGETS+=("${username} (no such account)")
            log_action "REMOVE_STUDENT" "$username" "REFUSED_NOT_FOUND"
            continue
        fi

        if ! is_student_user "$username"; then
            INVALID_TARGETS+=("${username} (not a student account)")
            log_action "REMOVE_STUDENT" "$username" "REFUSED_NOT_STUDENT"
            continue
        fi

        VALID_TARGETS+=("$username")
    done
}

# ---------------------------------------------------------------------------
# Selections
# ---------------------------------------------------------------------------

# Resolves the input, reports anything that will NOT be touched, and asks
# for destructive confirmation only when there is at least one valid target
# -- never before the input has been checked, and never for a request that
# resolves to nothing.
remove_list() {
    local input="$1"

    resolve_removal_targets "$input"

    if ((${#INVALID_TARGETS[@]} > 0)); then
        echo
        warn "The following requested ID(s) will NOT be processed:"
        printf '  - %s\n' "${INVALID_TARGETS[@]}"
    fi

    if ((${#VALID_TARGETS[@]} == 0)); then
        echo
        info "No valid student accounts to remove; nothing will be changed."
        NOTHING_TO_REMOVE=1
        return 1
    fi

    echo
    echo "Accounts that will be removed:"
    printf '  %s\n' "${VALID_TARGETS[@]}"
    echo
    describe_archive_action
    echo

    confirm "Remove ${#VALID_TARGETS[@]} account(s)?" || {
        info "Cancelled."
        return 0
    }

    local username
    for username in "${VALID_TARGETS[@]}"; do
        remove_student_account "$username" || true
    done
}

remove_all() {
    local students username

    mapfile -t students < <(get_student_users)

    if ((${#students[@]} == 0)); then
        info "No student accounts found."
        NOTHING_TO_REMOVE=1
        return 0
    fi

    echo
    echo "Student accounts to be removed:"
    printf '  %s\n' "${students[@]}"
    echo
    describe_archive_action
    echo

    confirm "Remove ALL ${#students[@]} student account(s)?" || {
        info "Cancelled."
        return 0
    }

    for username in "${students[@]}"; do
        remove_student_account "$username" || true
    done
}

remove_demo() {
    local students username reason
    local demo=() demo_display=()

    mapfile -t students < <(get_student_users)

    for username in "${students[@]}"; do
        reason=""

        is_demo_account "$username" && reason="matches demo pattern"

        if is_off_roster_account "$username"; then
            reason="${reason:+${reason}, }not in roster"
        fi

        if [[ -n "$reason" ]]; then
            demo+=("$username")
            demo_display+=("${username} (${reason})")
        fi
    done

    if ((${#demo[@]} == 0)); then
        info "No demo/test accounts found."
        info "Checked: username pattern '${DEMO_ACCOUNT_PATTERN}'$( \
            [[ -f "$STUDENT_ROSTER_CSV" ]] && printf ' and roster %s' "$STUDENT_ROSTER_CSV")."
        NOTHING_TO_REMOVE=1
        return 0
    fi

    echo
    echo "Demo/test accounts to be removed:"
    printf '  %s\n' "${demo_display[@]}"
    echo

    if [[ -f "$STUDENT_ROSTER_CSV" ]]; then
        warn "\"not in roster\" means the account is not listed in ${STUDENT_ROSTER_CSV}."
        warn "If a real student is missing from that file, cancel and fix the roster instead."
        echo
    fi

    describe_archive_action
    echo

    confirm "Remove ${#demo[@]} demo/test account(s)?" || {
        info "Cancelled."
        return 0
    }

    for username in "${demo[@]}"; do
        remove_student_account "$username" || true
    done
}

describe_archive_action() {
    if [[ "$DELETE_ARCHIVE" == "1" ]]; then
        warn "Submission archives WILL BE DELETED. This cannot be undone."
    else
        info "Submission archives will be KEPT under ${SUBMISSION_ROOT}."
    fi
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

ask_archive_action() {
    [[ -z "$DELETE_ARCHIVE" ]] || return 0

    echo
    echo "What should happen to the students' submitted work?"
    echo
    echo "  1. Keep archives   (recommended -- work is preserved)"
    echo "  2. Delete archives (permanent)"
    echo

    local choice
    choice="$(prompt_value "Choice" "1")"

    case "$choice" in
        1) DELETE_ARCHIVE=0 ;;
        2)
            confirm "Permanently delete submitted work? This cannot be undone." &&
                DELETE_ARCHIVE=1 || DELETE_ARCHIVE=0
            ;;
        *) die "Invalid choice." ;;
    esac
}

remove_menu() {
    header "Student Removal"

    echo "1. Remove selected students"
    echo "2. Remove all students"
    echo "3. Remove demo/test accounts"
    echo "4. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    [[ "$choice" == "4" ]] && return 0

    ask_archive_action

    case "$choice" in
        1)
            local input
            input="$(prompt_value "Student IDs (comma separated)")"
            [[ -n "$input" ]] || die "No student IDs supplied."

            # remove_list resolves the IDs and asks for confirmation itself,
            # after reporting anything that will not be touched -- not
            # before, the way this menu used to.
            remove_list "$input"
            ;;
        2) remove_all ;;
        3) remove_demo ;;
        *) die "Invalid choice." ;;
    esac
}

show_summary() {
    echo
    header "Student Removal Complete"

    printf '  %-24s %s\n' "Removed"          "$REMOVED"
    printf '  %-24s %s\n' "Failed"           "$FAILED"
    printf '  %-24s %s\n' "Remaining"        "$(count_users_in_group "$STUDENT_GROUP")"

    # What actually happened to archives, not what was merely requested.
    # DELETE_ARCHIVE=1 only means deletion was asked for; a nonexistent or
    # otherwise invalid account must never be reported as an archive
    # deletion, and neither should this line imply one happened when the
    # real count is zero.
    if [[ "$DELETE_ARCHIVE" == "1" ]]; then
        printf '  %-24s %s\n' "Archives deleted" "$ARCHIVES_DELETED"
        ((ARCHIVES_NOT_FOUND > 0)) &&
            printf '  %-24s %s\n' "Archives not found" "$ARCHIVES_NOT_FOUND"
        ((ARCHIVE_DELETE_FAILED > 0)) &&
            printf '  %-24s %s\n' "Archive deletions failed" "$ARCHIVE_DELETE_FAILED"
    else
        printf '  %-24s %s\n' "Archives kept" "$ARCHIVES_KEPT"
    fi

    echo
}

refresh_audit_rules() {
    local audit_module="${ASMS_MODULE_DIR}/generate_audit.sh"

    [[ -x "$audit_module" ]] || return 0

    info "Refreshing student audit rules..."

    ASMS_ASSUME_YES=1 "$audit_module" --generate >/dev/null 2>&1 ||
        warn "Audit rules could not be refreshed. Run Generate Audit Rules manually."
}

usage() {
    cat <<EOF
Usage: remove_students.sh [selection] [archive action]

Selection:
  --users a,b,c      Remove the named students
  --all              Remove every student account
  --demo             Remove demo/test accounts only

Archive action (required with a selection):
  --keep-archive     Keep submitted work under ${SUBMISSION_ROOT:-/srv/submissions}
  --delete-archive   Permanently delete submitted work

Other:
  -h, --help         Show this help

With no option an interactive menu is shown.

Set ASMS_ASSUME_YES=1 to skip confirmation prompts. This is how
reset_semester.sh drives this module.
EOF
}

main() {
    require_root
    require_command userdel
    require_command mountpoint

    local selection="" target=""

    while (($# > 0)); do
        case "$1" in
            --users)
                [[ -n "${2:-}" ]] || die "--users requires a comma-separated list."
                selection="users"; target="$2"; shift 2
                ;;
            --all)            selection="all";  shift ;;
            --demo)           selection="demo"; shift ;;
            --keep-archive)   DELETE_ARCHIVE=0; shift ;;
            --delete-archive) DELETE_ARCHIVE=1; shift ;;
            -h|--help)        usage; return 0 ;;
            *)                usage >&2; die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$selection" ]]; then
        remove_menu
    else
        # No implicit answer for irreversible data deletion.
        [[ -n "$DELETE_ARCHIVE" ]] ||
            die "Specify --keep-archive or --delete-archive."

        case "$selection" in
            users) remove_list "$target" || true ;;
            all)   remove_all ;;
            demo)  remove_demo ;;
        esac
    fi

    ((REMOVED > 0)) && refresh_audit_rules

    show_summary

    # A request that resolved to nothing (every ID nonexistent, protected,
    # malformed, or not a student) is not a failure -- FAILED stays 0, exactly
    # as it did before -- but it is not a successful removal either, so it
    # must not exit 0 as if it were.
    ((FAILED == 0)) && ((NOTHING_TO_REMOVE == 0))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
