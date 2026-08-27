#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: verify_server.sh
# Version: 2.0.0
#
# Read-only health and consistency checks. Changes nothing.
#
# The security checks are the point of this module. Anything reported as
# [FAIL] under "Student Isolation" means the invariant the whole system
# exists to hold is currently broken.
#
# Exit status: 0 when no check failed, 1 otherwise. assignment-admin and
# reset_semester.sh rely on that.
#
# Usage:
#   verify_server.sh              full report
#   verify_server.sh --security   security checks only
#   verify_server.sh --quiet      summary only
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

QUIET=0
SECURITY_ONLY=0

report() {
    ((QUIET)) || printf '%s\n' "$*"
}

pass()       { ((QUIET)) || printf '  [ OK ] %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn_check() { ((QUIET)) || printf '  [WARN] %s\n' "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail_check() { printf '  [FAIL] %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

section() {
    ((QUIET)) || header "$1"
}

check_file() {
    [[ -f "$1" ]] && pass "${2:-$1}" || fail_check "${2:-$1} — missing: $1"
}

check_dir() {
    [[ -d "$1" ]] && pass "${2:-$1}" || fail_check "${2:-$1} — missing: $1"
}

check_mode() {
    local path="$1" expected="$2" label="$3"

    [[ -e "$path" ]] || { warn_check "$label — not present: $path"; return; }

    local actual
    actual="$(stat -c '%a' "$path")"

    # stat drops a leading zero; compare numerically.
    if ((10#$actual == 10#$expected)); then
        pass "$label is $expected"
    else
        fail_check "$label is $actual (expected $expected): $path"
    fi
}

check_owner() {
    local path="$1" expected="$2" label="$3"

    [[ -e "$path" ]] || return

    local actual
    actual="$(stat -c '%U:%G' "$path")"

    [[ "$actual" == "$expected" ]] &&
        pass "$label is owned by $expected" ||
        fail_check "$label is owned by $actual (expected $expected): $path"
}

check_command() {
    if cmd_exists "$1"; then
        pass "$1 ($(command -v "$1"))"
    else
        ${2:-warn_check} "$1 is not installed${3:+ — $3}"
    fi
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

check_installation() {
    section "Installation"

    check_file "${ASMS_ROOT}/VERSION"          "VERSION"
    check_file "${ASMS_ROOT}/assignment-admin" "assignment-admin"
    check_file "$ASMS_CONFIG_FILE"             "config.conf"

    local module
    for module in utils.sh logger.sh generate_password.sh configure_mounts.sh \
                  provision_students.sh provision_faculty.sh remove_students.sh \
                  remove_faculty.sh install_devtools.sh generate_audit.sh \
                  backup_system.sh restore_backup.sh reset_semester.sh; do
        [[ -x "${ASMS_MODULE_DIR}/${module}" ]] &&
            pass "module ${module}" ||
            fail_check "module ${module} missing or not executable"
    done

    check_dir "$CREDENTIAL_DIR"        "Credentials directory"
    check_dir "${ASMS_ROOT}/logs"      "Logs directory"
    check_dir "$BACKUP_ROOT"           "Backups directory"
    check_dir "$SEMESTER_ARCHIVE_ROOT" "Semester archive directory"
    check_dir "$SUBMISSION_ROOT"       "Submission root"
}

check_dependencies() {
    section "Dependencies"

    # Required: provisioning fails without these.
    check_command setfacl fail_check "install the 'acl' package"
    check_command getfacl fail_check "install the 'acl' package"
    check_command auditctl fail_check "install the 'auditd' package"
    check_command augenrules fail_check "install the 'auditd' package"

    check_command mount
    check_command mountpoint
    check_command findmnt
    check_command useradd
    check_command tar
    check_command sha256sum

    if cmd_exists gcc; then
        pass "gcc (needed to build submit)"
    else
        warn_check "gcc is not installed — install.sh cannot rebuild submit"
    fi
}

check_groups() {
    section "Groups"

    group_exists "$STUDENT_GROUP" &&
        pass "Student group '$STUDENT_GROUP' exists (gid $(getent group "$STUDENT_GROUP" | cut -d: -f3))" ||
        fail_check "Student group '$STUDENT_GROUP' is missing"

    group_exists "$FACULTY_GROUP" &&
        pass "Faculty group '$FACULTY_GROUP' exists (gid $(getent group "$FACULTY_GROUP" | cut -d: -f3))" ||
        fail_check "Faculty group '$FACULTY_GROUP' is missing"
}

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------

check_submit_command() {
    section "Submit Command"

    if [[ ! -f "$SUBMIT_BIN" ]]; then
        fail_check "submit is not installed: $SUBMIT_BIN"
        return
    fi

    check_owner "$SUBMIT_BIN" "root:root" "submit"

    # 4755. Without the setuid bit it cannot write the root-owned archive;
    # Linux would also ignore the bit entirely if this were a script.
    local mode
    mode="$(stat -c '%a' "$SUBMIT_BIN")"

    if [[ "$mode" == "4755" ]]; then
        pass "submit is setuid root (4755)"
    else
        fail_check "submit mode is $mode (expected 4755) — it cannot write the archive"
    fi

    if file "$SUBMIT_BIN" 2>/dev/null | grep -q 'ELF'; then
        pass "submit is a compiled binary"
    else
        fail_check "submit is not a binary — Linux ignores setuid on scripts"
    fi

    if [[ ! -f "$SUBMIT_STORE_HELPER" ]]; then
        fail_check "store helper is missing: $SUBMIT_STORE_HELPER"
        return
    fi

    check_owner "$SUBMIT_STORE_HELPER" "root:root" "store helper"

    # Write access to the helper is root, because a setuid binary execs it.
    local helper_mode
    helper_mode="$(stat -c '%a' "$SUBMIT_STORE_HELPER")"

    if ((10#$helper_mode == 700)); then
        pass "store helper is root-only (700)"
    else
        fail_check "store helper mode is $helper_mode (expected 700) — writable by non-root means root escalation"
    fi
}

check_faculty_tools() {
    section "Faculty Tools"

    local tool="/usr/local/bin/assignment-check"

    if [[ ! -f "$tool" ]]; then
        warn_check "assignment-check is not installed: $tool"
        return
    fi

    check_owner "$tool" "root:root" "assignment-check"

    local mode
    mode="$(stat -c '%a' "$tool")"

    # Deliberately NOT setuid: this tool needs no privilege beyond what a
    # faculty account already has via ACLs. A setuid bit here would be an
    # unnecessary and unused escalation path.
    if ((10#$mode == 755)); then
        pass "assignment-check is $mode (not setuid, as intended)"
    else
        fail_check "assignment-check mode is $mode (expected 755)"
    fi

    if grep -q "@SUBMISSION_ROOT@\|@STUDENT_GROUP@\|@FACULTY_GROUP@" "$tool" 2>/dev/null; then
        fail_check "assignment-check still has unsubstituted @...@ placeholders — install.sh's sed step did not run correctly"
    else
        pass "assignment-check placeholders were substituted at install time"
    fi
}

check_archive_permissions() {
    section "Submission Archive"

    [[ -d "$SUBMISSION_ROOT" ]] || { fail_check "Submission root is missing"; return; }

    check_owner "$SUBMISSION_ROOT" "root:root" "Submission root"
    check_mode  "$SUBMISSION_ROOT" "$SUBMISSION_ROOT_MODE" "Submission root mode"

    # 0711 keeps the directory unlistable, so one student cannot enumerate
    # the others through it.
    local mode
    mode="$(stat -c '%a' "$SUBMISSION_ROOT")"

    if [[ "${mode: -1}" == "1" && "${mode:0:1}" == "0" ]] || [[ "$mode" == "711" ]]; then
        pass "Submission root is traverse-only (students cannot list it)"
    else
        warn_check "Submission root mode $mode may allow students to list other accounts"
    fi
}

check_capacity() {
    section "Capacity"

    if [[ -d "$SUBMISSION_ROOT" ]]; then
        local free_bytes
        free_bytes="$(df --output=avail -B1 "$SUBMISSION_ROOT" 2>/dev/null | tail -n 1 | tr -dc '0-9')"

        if [[ -n "$free_bytes" ]]; then
            if ((free_bytes >= SUBMISSION_MIN_FREE_BYTES)); then
                pass "Submission filesystem free space: $((free_bytes / 1048576)) MiB (floor: $((SUBMISSION_MIN_FREE_BYTES / 1048576)) MiB)"
            else
                fail_check "Submission filesystem free space: $((free_bytes / 1048576)) MiB -- below the $((SUBMISSION_MIN_FREE_BYTES / 1048576)) MiB floor asms-store enforces; new submissions will be refused"
            fi
        else
            warn_check "Could not determine free space for $SUBMISSION_ROOT"
        fi
    else
        warn_check "Submission root does not exist yet: $SUBMISSION_ROOT"
    fi

    report "  Per-student archive cap: $((MAX_STUDENT_ARCHIVE_BYTES / 1048576)) MiB"
    report ""
}

check_backup_signing() {
    section "Backup Signing"

    if [[ -n "$BACKUP_GPG_KEY_ID" ]]; then
        if cmd_exists gpg; then
            pass "Backups are signed with key ${BACKUP_GPG_KEY_ID}"
        else
            fail_check "BACKUP_GPG_KEY_ID is set but gpg is not installed -- backups are NOT being signed"
        fi
    else
        warn_check "BACKUP_GPG_KEY_ID is not set -- backups are corruption-evident only, not tamper-evident (see data/config.conf)"
    fi
}

check_credentials() {
    section "Credentials"

    check_owner "$CREDENTIAL_DIR" "root:root" "Credentials directory"
    check_mode  "$CREDENTIAL_DIR" "$CREDENTIAL_DIR_MODE" "Credentials directory mode"

    local file
    for file in "$STUDENT_CREDENTIALS" "$FACULTY_CREDENTIALS"; do
        [[ -f "$file" ]] || { warn_check "$(basename "$file") does not exist yet"; continue; }

        check_owner "$file" "root:root" "$(basename "$file")"
        check_mode  "$file" "$CREDENTIAL_FILE_MODE" "$(basename "$file") mode"
    done
}

# The checks that matter most: per student, the view must be mounted, point
# at their own archive, and be read-only.
check_student_isolation() {
    section "Student Isolation"

    local students
    mapfile -t students < <(get_student_users)

    if ((${#students[@]} == 0)); then
        warn_check "No student accounts provisioned"
        return
    fi

    report "  Checking ${#students[@]} student(s)."
    report ""

    local username archive mount_dir
    for username in "${students[@]}"; do
        archive="$(student_archive_path "$username")"
        mount_dir="$(student_mount_path "$username")"

        if [[ ! -d "$archive" ]]; then
            fail_check "$username: submission archive missing ($archive)"
            continue
        fi

        # The archive must not be owned by the student: an owner can chmod,
        # and a student who can chmod their archive can delete submitted work.
        local archive_owner
        archive_owner="$(stat -c '%U' "$archive")"

        if [[ "$archive_owner" == "root" ]]; then
            pass "$username: archive is root-owned"
        else
            fail_check "$username: archive is owned by '$archive_owner' — the student can modify submitted work"
        fi

        # The student's read access must come from an ACL naming them.
        if cmd_exists getfacl; then
            local acl
            acl="$(getfacl -p --omit-header "$archive" 2>/dev/null || true)"

            grep -q "^user:${username}:r-x" <<< "$acl" &&
                pass "$username: has read ACL on own archive" ||
                fail_check "$username: read ACL missing or wrong on own archive"

            grep -Eq "^user:${username}:.*w" <<< "$acl" &&
                fail_check "$username: ACL grants WRITE on own archive" ||
                pass "$username: ACL grants no write on own archive"

            grep -q "^group:${FACULTY_GROUP}:r-x" <<< "$acl" &&
                pass "$username: faculty can read this archive" ||
                warn_check "$username: faculty read ACL missing on this archive"

            # A masked ACL is the silent failure mode: the entries are
            # present but the mask makes them ineffective.
            if grep -q '^mask::---' <<< "$acl"; then
                fail_check "$username: ACL mask is --- , so all ACL entries are ineffective (something ran chmod on the archive)"
            fi
        else
            warn_check "$username: getfacl unavailable, cannot verify ACLs"
        fi

        # The view itself.
        if ! mountpoint -q "$mount_dir" 2>/dev/null; then
            fail_check "$username: submission view is not mounted ($mount_dir)"
            continue
        fi

        local target_id archive_id
        target_id="$(stat -c '%d:%i' "$mount_dir" 2>/dev/null || echo x)"
        archive_id="$(stat -c '%d:%i' "$archive" 2>/dev/null || echo y)"

        [[ "$target_id" == "$archive_id" ]] &&
            pass "$username: view resolves to their own archive" ||
            fail_check "$username: view does NOT resolve to their own archive"

        local options
        options="$(findmnt -n -o OPTIONS --first-only "$mount_dir" 2>/dev/null || true)"

        if [[ ",${options}," == *",ro,"* ]]; then
            pass "$username: view is read-only"
        else
            fail_check "$username: view is NOT read-only — the student can modify submitted work"
        fi

        # fstab entry, or the view does not come back after a reboot.
        if grep -Eq "^[[:space:]]*${archive}[[:space:]]+${mount_dir}[[:space:]]" /etc/fstab 2>/dev/null; then
            pass "$username: fstab entry present (survives reboot)"
        else
            fail_check "$username: no fstab entry — the view will not return after a reboot"
        fi

        # The working area must exist and belong to the student.
        local assignments
        assignments="$(student_assignments_path "$username")"

        if [[ -d "$assignments" ]]; then
            local owner
            owner="$(stat -c '%U' "$assignments")"

            [[ "$owner" == "$username" ]] &&
                pass "$username: assignments directory is theirs" ||
                fail_check "$username: assignments directory owned by $owner"
        else
            fail_check "$username: assignments directory missing"
        fi
    done
}

check_boot_persistence() {
    section "Reboot Persistence"

    if ! cmd_exists systemctl; then
        warn_check "systemd not present; mounts rely on /etc/fstab alone"
        return
    fi

    if systemctl is-enabled asms-mounts.service >/dev/null 2>&1; then
        pass "asms-mounts.service is enabled"
    else
        warn_check "asms-mounts.service is not enabled — on util-linux < 2.37 views may return read-write after reboot"
    fi
}

check_audit() {
    section "Audit"

    if systemctl is-active --quiet auditd 2>/dev/null; then
        pass "auditd is running"
    else
        fail_check "auditd is not running"
    fi

    [[ -f "$AUDIT_RULE_FILE" ]] &&
        pass "ASMS audit rule file present" ||
        warn_check "No ASMS audit rule file at $AUDIT_RULE_FILE"

    if ! cmd_exists auditctl; then
        fail_check "auditctl is not available"
        return
    fi

    local live
    live="$(auditctl -l 2>/dev/null || true)"

    if grep -Fq "$AUDIT_KEY_PREFIX" <<< "$live"; then
        pass "Student audit rules are live ($(grep -Fc "$AUDIT_KEY_PREFIX" <<< "$live") rules)"
    else
        warn_check "No live ${AUDIT_KEY_PREFIX}_* rules — run Generate Audit Rules"
    fi

    # Faculty must not be caught by student rules.
    local student_gid faculty_gid
    student_gid="$(getent group "$STUDENT_GROUP" | cut -d: -f3)"
    faculty_gid="$(getent group "$FACULTY_GROUP" | cut -d: -f3)"

    if [[ -n "$faculty_gid" ]] && grep -Fq "gid=${faculty_gid}" <<< "$live"; then
        fail_check "Audit rules match the faculty group — they should cover students only"
    elif [[ -n "$student_gid" ]]; then
        pass "Audit rules target students only (gid ${student_gid})"
    fi
}

check_accounts() {
    section "Accounts"

    local students faculty
    mapfile -t students < <(get_student_users)
    mapfile -t faculty  < <(get_faculty_users)

    report "  Students: ${#students[@]}"
    report "  Faculty : ${#faculty[@]}"
    report ""

    ((${#students[@]} > 0)) || warn_check "No student accounts provisioned"
    ((${#faculty[@]}  > 0)) || warn_check "No faculty accounts provisioned"

    local username
    for username in "${students[@]}"; do
        user_exists "$username" ||
            fail_check "$username is enumerated but has no account"
    done

    # An account in both groups blurs the trust boundary the whole model
    # rests on.
    for username in "${students[@]}"; do
        is_faculty_user "$username" &&
            fail_check "$username is in BOTH the student and faculty groups"
    done

    ((FAIL_COUNT == 0)) && pass "No account is both student and faculty"
}

check_development_tools() {
    section "Development Environment"

    local command_name
    for command_name in vim nano gcc g++ make cmake gdb git python3 java javac; do
        check_command "$command_name"
    done
}

# ---------------------------------------------------------------------------

summary() {
    header "Verification Summary"

    printf '  Passed   : %d\n' "$PASS_COUNT"
    printf '  Warnings : %d\n' "$WARN_COUNT"
    printf '  Failed   : %d\n' "$FAIL_COUNT"
    echo

    log_action "VERIFY_SERVER" "$(hostname_short)" \
        "pass=${PASS_COUNT};warn=${WARN_COUNT};fail=${FAIL_COUNT}"

    if ((FAIL_COUNT > 0)); then
        error "Verification found ${FAIL_COUNT} failure(s)."
        echo
        warn "Failures under 'Student Isolation' mean submitted work is not protected."
        warn "Re-run provisioning, or: configure_mounts.sh --repair-all"
        return 1
    fi

    if ((WARN_COUNT > 0)); then
        warn "Verification completed with ${WARN_COUNT} warning(s)."
        return 0
    fi

    success "ASMS verification passed."
}

usage() {
    cat <<EOF
Usage: verify_server.sh [option]

  --security   Run the security checks only
  --quiet      Print the summary and failures only
  -h, --help   Show this help

Exit status is 0 when nothing failed, 1 otherwise.
EOF
}

main() {
    while (($# > 0)); do
        case "$1" in
            --security) SECURITY_ONLY=1; shift ;;
            --quiet)    QUIET=1; shift ;;
            -h|--help)  usage; return 0 ;;
            *)          usage >&2; die "Unknown option: $1" ;;
        esac
    done

    ((QUIET)) || header "ASMS Server Verification"

    if ((SECURITY_ONLY)); then
        check_submit_command
        check_archive_permissions
        check_credentials
        check_student_isolation
        check_backup_signing
    else
        check_installation
        check_dependencies
        check_groups
        check_submit_command
        check_faculty_tools
        check_archive_permissions
        check_credentials
        check_accounts
        check_student_isolation
        check_boot_persistence
        check_audit
        check_capacity
        check_backup_signing
        check_development_tools
    fi

    summary
}

main "$@"
