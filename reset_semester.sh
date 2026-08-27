#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: reset_semester.sh
# Version: 2.0.0
#
# Controlled semester transition.
#
#   1. Full backup (the recovery point for the whole operation)
#   2. Archive the current submission tree to SEMESTER_ARCHIVE_ROOT
#   3. Verify the archive copy before anything is destroyed
#   4. Remove student accounts, mounts, fstab entries and archives
#   5. Recreate an empty submission root
#   6. Regenerate audit rules
#   7. Verify the server
#
# Faculty accounts are not touched.
#
# Account removal is delegated to remove_students.sh, driven with
# ASMS_ASSUME_YES. The scaffold reimplemented it here with a bare `userdel -r`
# and unmounted separately -- with two consequences: the removal safeguards
# (protected accounts, refusing to proceed while the view is mounted) did not
# apply, and a `userdel -r` racing a still-mounted view deletes through the
# bind mount into the archive it was meant to preserve.
#
# Usage:
#   reset_semester.sh              interactive
#   reset_semester.sh --confirm    non-interactive (for scripted use)
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

RESET_ID="$(timestamp_id)"
RESET_ARCHIVE="${SEMESTER_ARCHIVE_ROOT}/semester-${RESET_ID}"

STUDENT_LIST=()

# ---------------------------------------------------------------------------

check_dependencies() {
    local module

    for module in backup_system.sh remove_students.sh generate_audit.sh \
                  configure_mounts.sh verify_server.sh; do
        [[ -x "${ASMS_MODULE_DIR}/${module}" ]] ||
            die "Required module missing or not executable: $module"
    done
}

snapshot_students() {
    mapfile -t STUDENT_LIST < <(get_student_users)
}

create_full_backup() {
    header "Step 1 of 7: Full backup"

    ASMS_ASSUME_YES=1 "${ASMS_MODULE_DIR}/backup_system.sh" --full ||
        die "Backup failed. Semester reset aborted -- nothing has been changed."

    success "Recovery point created."
}

# The submission tree is copied out before any account is removed. This is
# the copy that outlives the semester, so it is verified before the
# destructive phase rather than trusted.
archive_submissions() {
    header "Step 2 of 7: Archive current submissions"

    install -d -o root -g root -m 0700 "$SEMESTER_ARCHIVE_ROOT"

    if [[ ! -d "$SUBMISSION_ROOT" ]] ||
       [[ -z "$(find "$SUBMISSION_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        info "No submissions to archive."
        return 0
    fi

    install -d -o root -g root -m 0700 "$RESET_ARCHIVE"

    info "Copying submissions to ${RESET_ARCHIVE}..."

    # -a preserves ownership, modes and ACLs, so the archived copy keeps the
    # access model the submissions were stored under.
    cp -a "${SUBMISSION_ROOT}/." "${RESET_ARCHIVE}/" ||
        die "Failed to archive submissions. Semester reset aborted."

    log_action "SEMESTER_ARCHIVE" "$RESET_ARCHIVE" "SUCCESS"
    success "Submissions archived."
}

# Confirms the archived copy matches the original before the original is
# destroyed. Without this, a partial copy would only be discovered after the
# source was gone.
verify_archive() {
    header "Step 3 of 7: Verify the archived copy"

    [[ -d "$RESET_ARCHIVE" ]] || { info "Nothing was archived; skipping."; return 0; }

    local source_files archive_files
    source_files="$(find "$SUBMISSION_ROOT" -type f | wc -l)"
    archive_files="$(find "$RESET_ARCHIVE" -type f | wc -l)"

    printf '  %-24s %s\n' "Files in archive root" "$source_files"
    printf '  %-24s %s\n' "Files archived"        "$archive_files"

    ((source_files == archive_files)) || {
        error "File count mismatch: ${source_files} vs ${archive_files}."
        die "Archived copy is incomplete. Semester reset aborted -- nothing removed."
    }

    # A checksum manifest of the archived copy, so its integrity can be
    # confirmed months later when it is the only remaining copy.
    local manifest_tmp
    manifest_tmp="$(mktemp)"

    ( cd "$RESET_ARCHIVE" && find . -type f -print0 | sort -z |
        xargs -0 --no-run-if-empty sha256sum ) > "$manifest_tmp"

    mv "$manifest_tmp" "${RESET_ARCHIVE}.MANIFEST.sha256"
    chmod 0600 "${RESET_ARCHIVE}.MANIFEST.sha256"

    success "Archived copy verified (${archive_files} files)."
}

remove_students() {
    header "Step 4 of 7: Remove student accounts"

    if ((${#STUDENT_LIST[@]} == 0)); then
        info "No student accounts to remove."
        return 0
    fi

    local list
    list="$(IFS=,; printf '%s' "${STUDENT_LIST[*]}")"

    # The one implementation of student removal, with all its safeguards:
    # protected accounts, unmount-before-userdel, fstab cleanup, credential
    # cleanup. Archives are deleted because they were copied out in step 2
    # and verified in step 3.
    ASMS_ASSUME_YES=1 "${ASMS_MODULE_DIR}/remove_students.sh" \
        --users "$list" --delete-archive ||
        die "Student removal reported failures. Semester reset stopped.
The archived copy at ${RESET_ARCHIVE} is intact."

    success "Student accounts removed."
}

recreate_submission_root() {
    header "Step 5 of 7: Recreate submission root"

    [[ -d "$SUBMISSION_ROOT" ]] &&
        [[ -z "$(find "$SUBMISSION_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] &&
        info "Submission root is empty."

    install -d -o root -g root -m "$SUBMISSION_ROOT_MODE" "$SUBMISSION_ROOT"

    success "Submission root ready: ${SUBMISSION_ROOT} (root:root ${SUBMISSION_ROOT_MODE})"
}

regenerate_audit() {
    header "Step 6 of 7: Regenerate audit rules"

    if ASMS_ASSUME_YES=1 "${ASMS_MODULE_DIR}/generate_audit.sh" --generate; then
        success "Audit rules regenerated."
    else
        warn "Audit rules could not be regenerated. Run Generate Audit Rules manually."
    fi
}

run_verification() {
    header "Step 7 of 7: Verify server"

    "${ASMS_MODULE_DIR}/verify_server.sh" || {
        warn "Verification reported findings. Review them before provisioning."
        return 1
    }
}

# ---------------------------------------------------------------------------

show_plan() {
    header "Semester Reset"

    snapshot_students

    printf '  %-28s %s\n' "Students to be removed" "${#STUDENT_LIST[@]}"
    ((${#STUDENT_LIST[@]} > 0)) && printf '    %s\n' "${STUDENT_LIST[@]}"

    printf '  %-28s %s\n' "Faculty (untouched)" "$(count_users_in_group "$FACULTY_GROUP")"
    printf '  %-28s %s\n' "Submissions archive to" "$RESET_ARCHIVE"
    echo

    warn "This operation is destructive."
    echo
    echo "  It will:"
    echo "    - take a full backup"
    echo "    - copy all current submissions to the semester archive"
    echo "    - verify that copy"
    echo "    - remove every student account, home directory and mount"
    echo "    - delete the live submission archives (the copy is kept)"
    echo "    - recreate an empty submission root"
    echo "    - regenerate audit rules"
    echo
    echo "  It will NOT:"
    echo "    - remove faculty accounts"
    echo "    - create next semester's students (run provisioning separately)"
    echo
}

show_result() {
    header "Semester Reset Complete"

    printf '  %-28s %s\n' "Semester archive" "$RESET_ARCHIVE"
    printf '  %-28s %s\n' "Archive manifest" "${RESET_ARCHIVE}.MANIFEST.sha256"
    printf '  %-28s %s\n' "Backups"          "$BACKUP_ROOT"
    printf '  %-28s %s\n' "Students now"     "$(count_users_in_group "$STUDENT_GROUP")"
    printf '  %-28s %s\n' "Faculty now"      "$(count_users_in_group "$FACULTY_GROUP")"
    echo

    warn "Run Provision Students to create the new semester's accounts."
    echo
}

usage() {
    cat <<EOF
Usage: reset_semester.sh [option]

  --confirm    Proceed without the interactive confirmation prompt
  -h, --help   Show this help
EOF
}

main() {
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        --confirm) ASMS_ASSUME_YES=1 ;;
        "")        ;;
        *)         usage >&2; die "Unknown option: $1" ;;
    esac

    check_dependencies
    show_plan

    confirm "Proceed with semester reset?" || {
        info "Semester reset cancelled. Nothing was changed."
        log_action "SEMESTER_RESET" "all" "CANCELLED"
        return 0
    }

    log_action "SEMESTER_RESET" "$RESET_ID" "STARTED"

    create_full_backup
    archive_submissions
    verify_archive
    remove_students
    recreate_submission_root
    regenerate_audit

    log_action "SEMESTER_RESET" "$RESET_ID" "SUCCESS"

    show_result

    run_verification
}

main "$@"
