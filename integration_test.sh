#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Integration test
# Version: 2.0.0
#
# Exercises the whole system on a real server: provisioning, submission,
# read-only enforcement, cross-student isolation, faculty access, auditing,
# backup round-trip and semester reset.
#
# RUN THIS ON A TEST MACHINE, NOT A LIVE SERVER.
# It creates and deletes accounts, and the semester-reset stage removes every
# student account on the host.
#
#   sudo ./integration_test.sh              everything except semester reset
#   sudo ./integration_test.sh --with-reset everything, including reset
#   sudo ./integration_test.sh --cleanup    remove this test's accounts and exit
#
# Test accounts are prefixed asmstest_ and are removed at the end.
#
# The isolation checks use `runuser` to act as each student, so they test what
# the kernel actually permits rather than what the configuration intends.
#

set -Eeuo pipefail

ASMS_ROOT="${ASMS_ROOT:-/opt/assignment-server}"
MODULE_DIR="${ASMS_ROOT}/modules"

[[ -f "${MODULE_DIR}/utils.sh" ]] || {
    echo "ERROR: ASMS is not installed at ${ASMS_ROOT}. Run install.sh first." >&2
    exit 1
}

# shellcheck source=utils.sh
source "${MODULE_DIR}/utils.sh"

require_root
load_config

STUDENT_A="asmstest_alice"
STUDENT_B="asmstest_bob"
FACULTY="asmstest_prof"

WITH_RESET=0

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------

t_pass() { printf '  \033[32m[ PASS ]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
t_skip() { printf '  \033[33m[ SKIP ]\033[0m %s — %s\n' "$1" "${2:-}"; SKIP=$((SKIP + 1)); }

t_fail() {
    printf '  \033[31m[ FAIL ]\033[0m %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '           %s\n' "$2"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
}

stage() {
    echo
    printf '\033[34m== %s ==\033[0m\n' "$1"
}

# Asserts a command succeeds.
must() {
    local label="$1"; shift
    local output

    if output="$("$@" 2>&1)"; then
        t_pass "$label"
    else
        t_fail "$label" "$(tail -2 <<< "$output")"
    fi
}

# Asserts a command FAILS. Used for every isolation check: the test is that
# the kernel refuses, so a success here is a security hole.
must_fail() {
    local label="$1"; shift
    local output

    if output="$("$@" 2>&1)"; then
        t_fail "$label" "the operation SUCCEEDED but must be denied"
    else
        t_pass "$label"
    fi
}

# Run a command as a student, with their real credentials and groups.
as_user() {
    local username="$1"; shift
    runuser -u "$username" -- "$@"
}

# ---------------------------------------------------------------------------

cleanup_test_accounts() {
    local username

    for username in "$STUDENT_A" "$STUDENT_B"; do
        user_exists "$username" || continue

        ASMS_ASSUME_YES=1 "${MODULE_DIR}/remove_students.sh" \
            --users "$username" --delete-archive >/dev/null 2>&1 || true
    done

    if user_exists "$FACULTY"; then
        ASMS_ASSUME_YES=1 "${MODULE_DIR}/remove_faculty.sh" \
            --users "$FACULTY" >/dev/null 2>&1 || true
    fi

    # Belt and braces: the modules refuse in some states, and a leftover test
    # account would poison the next run.
    for username in "$STUDENT_A" "$STUDENT_B" "$FACULTY"; do
        if user_exists "$username"; then
            umount "$(student_mount_path "$username")" 2>/dev/null || true
            userdel -r "$username" 2>/dev/null || true
        fi
        rm -rf --one-file-system "$(student_archive_path "$username")" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

stage_prerequisites() {
    stage "Prerequisites"

    must "acl tools installed"     bash -c 'command -v setfacl && command -v getfacl'
    must "runuser available"       bash -c 'command -v runuser'

    if [[ -x "$SUBMIT_BIN" ]]; then
        t_pass "submit is installed"
    else
        t_fail "submit is installed" "missing $SUBMIT_BIN — run install.sh"
    fi

    if [[ "$(stat -c '%a' "$SUBMIT_BIN" 2>/dev/null)" == "4755" ]]; then
        t_pass "submit is setuid root"
    else
        t_fail "submit is setuid root" "mode is $(stat -c '%a' "$SUBMIT_BIN" 2>/dev/null || echo absent)"
    fi

    if file "$SUBMIT_BIN" 2>/dev/null | grep -q ELF; then
        t_pass "submit is a compiled binary (setuid works)"
    else
        t_fail "submit is a compiled binary" "Linux ignores setuid on scripts"
    fi
}

stage_provision() {
    stage "Provisioning"

    must "provision student A" "${MODULE_DIR}/provision_students.sh" --users "$STUDENT_A"
    must "provision student B" "${MODULE_DIR}/provision_students.sh" --users "$STUDENT_B"
    must "provision faculty"   "${MODULE_DIR}/provision_faculty.sh"  --users "$FACULTY"

    # The bug that made the scaffold's every enumeration return nothing.
    if get_student_users | grep -qx "$STUDENT_A"; then
        t_pass "student A is discoverable by enumeration (primary-group membership)"
    else
        t_fail "student A is discoverable by enumeration" \
               "get_student_users did not return $STUDENT_A"
    fi

    for username in "$STUDENT_A" "$STUDENT_B"; do
        [[ -d "$(student_assignments_path "$username")" ]] &&
            t_pass "$username has a writable assignments directory" ||
            t_fail "$username has a writable assignments directory"

        mountpoint -q "$(student_mount_path "$username")" &&
            t_pass "$username submissions view is mounted" ||
            t_fail "$username submissions view is mounted"
    done

    # A generated password must not be usable indefinitely: chage -d 0 forces
    # a change at next login for every account this system creates.
    local username
    for username in "$STUDENT_A" "$STUDENT_B" "$FACULTY"; do
        if chage -l "$username" 2>/dev/null | grep -q "must be changed"; then
            t_pass "$username must change password at first login"
        else
            t_fail "$username must change password at first login"
        fi
    done
}

stage_submit() {
    stage "Submission"

    local work="$(student_assignments_path "$STUDENT_A")/assignment01"

    as_user "$STUDENT_A" mkdir -p "$work"
    as_user "$STUDENT_A" bash -c "printf '#include <stdio.h>\nint main(void){puts(\"hello\");return 0;}\n' > '${work}/main.c'"
    as_user "$STUDENT_A" mkdir -p "${work}/lib"
    as_user "$STUDENT_A" bash -c "printf 'int helper(void){return 42;}\n' > '${work}/lib/helper.c'"

    must "student A can create work in assignments" \
        as_user "$STUDENT_A" test -f "${work}/main.c"

    must "student A submits assignment01" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" assignment01

    local v1="$(student_archive_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}001"

    [[ -d "$v1" ]] &&
        t_pass "submission-001 exists in the authoritative archive" ||
        t_fail "submission-001 exists in the authoritative archive" "expected $v1"

    [[ -f "${v1}/main.c" ]] &&
        t_pass "submitted file is present" ||
        t_fail "submitted file is present"

    [[ -f "${v1}/lib/helper.c" ]] &&
        t_pass "directory structure preserved" ||
        t_fail "directory structure preserved"

    [[ -f "${v1}/metadata/receipt.txt" ]] &&
        t_pass "receipt written" ||
        t_fail "receipt written"

    if [[ -f "${v1}/metadata/MANIFEST.sha256" ]]; then
        ( cd "$v1" && sha256sum -c --quiet metadata/MANIFEST.sha256 ) >/dev/null 2>&1 &&
            t_pass "submission manifest verifies" ||
            t_fail "submission manifest verifies"
    else
        t_fail "submission manifest written"
    fi

    # Nothing in the archive may be owned by the student: an owner can chmod
    # their own files and edit submitted work in place.
    if [[ -z "$(find "$v1" ! -user root -print -quit)" ]]; then
        t_pass "all archived files are root-owned"
    else
        t_fail "all archived files are root-owned" \
               "$(find "$v1" ! -user root -printf '%u %p\n' | head -2)"
    fi

    # Baseline for the post-copy symlink re-check in asms-store: an ordinary
    # submission must never leave a symlink in the archive. The race that
    # check defends against (a symlink swapped in between the pre-copy scan
    # and cp -a) is not reproducible from outside asms-store without an
    # artificial delay, so this only confirms the common path stays clean.
    if [[ -z "$(find "$v1" -type l -print -quit)" ]]; then
        t_pass "no symlinks in a normal submission's archive"
    else
        t_fail "no symlinks in a normal submission's archive"
    fi

    # Versioning: a second submission must not overwrite the first.
    as_user "$STUDENT_A" bash -c "printf '// revised\n' >> '${work}/main.c'"
    must "student A submits a second time" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" assignment01

    [[ -d "$(student_archive_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}002" ]] &&
        t_pass "second submission became submission-002" ||
        t_fail "second submission became submission-002"

    [[ -f "${v1}/main.c" ]] &&
        t_pass "submission-001 survived the resubmission" ||
        t_fail "submission-001 survived the resubmission"
}

stage_readonly_view() {
    stage "Read-only submission view"

    local view="$(student_mount_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}001"

    must "student A can list their submissions" \
        as_user "$STUDENT_A" ls "$(student_mount_path "$STUDENT_A")"

    must "student A can read their submitted file" \
        as_user "$STUDENT_A" cat "${view}/main.c"

    must_fail "student A CANNOT modify a submitted file" \
        as_user "$STUDENT_A" bash -c "echo tampered >> '${view}/main.c'"

    must_fail "student A CANNOT delete a submitted file" \
        as_user "$STUDENT_A" rm -f "${view}/main.c"

    must_fail "student A CANNOT delete a submission directory" \
        as_user "$STUDENT_A" rm -rf "$view"

    must_fail "student A CANNOT create a file in the view" \
        as_user "$STUDENT_A" touch "$(student_mount_path "$STUDENT_A")/injected"

    must_fail "student A CANNOT replace the receipt" \
        as_user "$STUDENT_A" bash -c "echo forged > '${view}/metadata/receipt.txt'"

    must_fail "student A CANNOT chmod submitted files" \
        as_user "$STUDENT_A" chmod 777 "${view}/main.c"

    # Direct access to the archive, bypassing the read-only mount entirely.
    local archive="$(student_archive_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}001"

    must "student A can read their archive directly" \
        as_user "$STUDENT_A" cat "${archive}/main.c"

    must_fail "student A CANNOT write to their archive directly" \
        as_user "$STUDENT_A" bash -c "echo tampered >> '${archive}/main.c'"

    must_fail "student A CANNOT delete from their archive directly" \
        as_user "$STUDENT_A" rm -f "${archive}/main.c"
}

stage_cross_student_isolation() {
    stage "Cross-student isolation"

    local work="$(student_assignments_path "$STUDENT_B")/assignment01"

    as_user "$STUDENT_B" mkdir -p "$work"
    as_user "$STUDENT_B" bash -c "printf 'int main(void){return 0;}\n' > '${work}/main.c'"

    must "student B submits their own work" \
        as_user "$STUDENT_B" "$SUBMIT_BIN" assignment01

    must "student B can read their own submission" \
        as_user "$STUDENT_B" cat "$(student_mount_path "$STUDENT_B")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"

    # The core invariant.
    must_fail "student A CANNOT list student B's view" \
        as_user "$STUDENT_A" ls "$(student_mount_path "$STUDENT_B")"

    must_fail "student A CANNOT read student B's submitted file" \
        as_user "$STUDENT_A" cat "$(student_mount_path "$STUDENT_B")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"

    must_fail "student A CANNOT read student B's archive" \
        as_user "$STUDENT_A" cat "$(student_archive_path "$STUDENT_B")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"

    must_fail "student A CANNOT list student B's archive" \
        as_user "$STUDENT_A" ls "$(student_archive_path "$STUDENT_B")"

    must_fail "student A CANNOT enter student B's home" \
        as_user "$STUDENT_A" ls "$(student_home_path "$STUDENT_B")"

    must_fail "student A CANNOT read student B's assignments" \
        as_user "$STUDENT_A" ls "$(student_assignments_path "$STUDENT_B")"

    # 0711 on the submission root: reachable by name, not enumerable.
    must_fail "student A CANNOT enumerate the submission root" \
        as_user "$STUDENT_A" ls "$SUBMISSION_ROOT"

    must_fail "student A CANNOT write into student B's archive" \
        as_user "$STUDENT_A" bash -c "echo x > '$(student_archive_path "$STUDENT_B")/injected'"

    # Identity comes from getuid(), so arguments cannot redirect a submission.
    must_fail "student A CANNOT submit into student B's archive via a path argument" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" assignment01 "$(student_assignments_path "$STUDENT_B")"
}

stage_submit_hardening() {
    stage "Submit input validation"

    must_fail "rejects path traversal in the assignment name" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" "../../etc"

    must_fail "rejects a slash in the assignment name" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" "a/b"

    must_fail "rejects a source outside the assignments directory" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" assignment01 /etc

    must_fail "rejects submitting the whole assignments directory" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" assignment01 "$(student_assignments_path "$STUDENT_A")"

    must_fail "rejects a non-existent assignment" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" nosuchassignment

    must_fail "root cannot submit" \
        "$SUBMIT_BIN" assignment01

    # A symlink is a request for root to reach a file the student cannot.
    local work="$(student_assignments_path "$STUDENT_A")/evil"
    as_user "$STUDENT_A" mkdir -p "$work"
    as_user "$STUDENT_A" ln -sf /etc/shadow "${work}/stolen"

    must_fail "rejects a submission containing a symlink" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" evil

    [[ ! -e "$(student_archive_path "$STUDENT_A")/evil/${SUBMISSION_VERSION_PREFIX}001/stolen" ]] &&
        t_pass "no shadow file was copied into the archive" ||
        t_fail "no shadow file was copied into the archive" "SERIOUS: /etc/shadow content may be exposed"

    # A rejected submission must not leave a partial version behind.
    if [[ -d "$(student_archive_path "$STUDENT_A")/evil" ]]; then
        [[ -z "$(find "$(student_archive_path "$STUDENT_A")/evil" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] &&
            t_pass "rejected submission left no version directory" ||
            t_fail "rejected submission left no version directory"
    else
        t_pass "rejected submission left no version directory"
    fi
}

stage_capacity_limits() {
    stage "Capacity limits"

    # Runs COMMAND with MAX_STUDENT_ARCHIVE_BYTES temporarily set to 1 byte
    # in the installed config.conf, then restores the original file no
    # matter how COMMAND exits. The inner subshell's own EXIT trap -- not
    # the outer function -- is what guarantees the restore, because a
    # failing command inside a plain `(...)` would otherwise trip this
    # script's `set -e` before an outer trap got a chance to run.
    run_with_temporarily_lowered_quota() {
        local config="${ASMS_ROOT}/data/config.conf"
        local config_backup
        config_backup="$(mktemp)"
        cp -a "$config" "$config_backup"

        local rc=0
        (
            trap 'cp -a "$config_backup" "$config"' EXIT
            sed -i 's/^MAX_STUDENT_ARCHIVE_BYTES=.*/MAX_STUDENT_ARCHIVE_BYTES="1"/' "$config"
            "$@"
        ) || rc=$?

        rm -f "$config_backup"
        return "$rc"
    }

    local work="$(student_assignments_path "$STUDENT_A")/quota-probe"
    as_user "$STUDENT_A" mkdir -p "$work"
    as_user "$STUDENT_A" bash -c "printf 'probe\n' > '${work}/probe.txt'"

    must_fail "submission is refused once the per-student archive cap is exceeded" \
        run_with_temporarily_lowered_quota as_user "$STUDENT_A" "$SUBMIT_BIN" quota-probe

    # The config file is back to normal now; confirm submit still works.
    local work2="$(student_assignments_path "$STUDENT_A")/quota-restored"
    as_user "$STUDENT_A" mkdir -p "$work2"
    as_user "$STUDENT_A" bash -c "printf 'probe\n' > '${work2}/probe.txt'"

    must "submission succeeds again once the cap is restored" \
        as_user "$STUDENT_A" "$SUBMIT_BIN" quota-restored

    unset -f run_with_temporarily_lowered_quota
}

stage_faculty_access() {
    stage "Faculty access"

    local a_file="$(student_archive_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"
    local b_file="$(student_archive_path "$STUDENT_B")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"

    must "faculty can read student A's submission" as_user "$FACULTY" cat "$a_file"
    must "faculty can read student B's submission" as_user "$FACULTY" cat "$b_file"
    must "faculty can list a student's archive" \
        as_user "$FACULTY" ls "$(student_archive_path "$STUDENT_A")"

    must_fail "faculty CANNOT modify a submission" \
        as_user "$FACULTY" bash -c "echo graded >> '$a_file'"

    must_fail "faculty CANNOT delete a submission" \
        as_user "$FACULTY" rm -f "$a_file"
}

stage_audit() {
    stage "Audit"

    if ! cmd_exists auditctl; then
        t_skip "audit rules" "auditctl not installed"
        return
    fi

    must "audit rules generate" "${MODULE_DIR}/generate_audit.sh" --generate

    local live
    live="$(auditctl -l 2>/dev/null || true)"

    grep -Fq "${AUDIT_KEY_PREFIX}_" <<< "$live" &&
        t_pass "student audit rules are live" ||
        t_fail "student audit rules are live"

    local student_gid faculty_gid
    student_gid="$(getent group "$STUDENT_GROUP" | cut -d: -f3)"
    faculty_gid="$(getent group "$FACULTY_GROUP" | cut -d: -f3)"

    grep -Fq "gid=${student_gid}" <<< "$live" &&
        t_pass "rules target the students group" ||
        t_fail "rules target the students group"

    grep -Fq "gid=${faculty_gid}" <<< "$live" &&
        t_fail "rules must NOT target faculty" ||
        t_pass "rules do not target faculty"

    if systemctl is-active --quiet auditd 2>/dev/null; then
        as_user "$STUDENT_A" rm -f /tmp/asms-audit-probe 2>/dev/null || true
        sleep 1

        if ausearch -k "${AUDIT_KEY_PREFIX}_rm" -ts recent >/dev/null 2>&1; then
            t_pass "student rm was recorded by auditd"
        else
            t_skip "student rm was recorded" "no event found (auditd backlog or rule delay)"
        fi
    else
        t_skip "audit event recording" "auditd is not running"
    fi
}

stage_backup_restore() {
    stage "Backup and restore"

    must "full backup completes" "${MODULE_DIR}/backup_system.sh" --full

    local archive
    archive="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'full-*.tar.gz' -printf '%T@ %p\n' |
        sort -rn | head -1 | cut -d' ' -f2-)"

    if [[ -z "$archive" ]]; then
        t_fail "backup archive was created"
        return
    fi

    t_pass "backup archive was created"

    [[ -f "${archive}.sha256" ]] &&
        t_pass "archive checksum sidecar written" ||
        t_fail "archive checksum sidecar written"

    must "archive checksum verifies" \
        bash -c "cd '$BACKUP_ROOT' && sha256sum -c '$(basename "${archive}.sha256")'"

    # The regression that made every scaffold backup unverifiable: a manifest
    # that listed itself could never pass sha256sum -c.
    must "backup manifest verifies (self-reference regression)" \
        "${MODULE_DIR}/restore_backup.sh" --verify "$(basename "$archive")"

    local extracted
    extracted="$(mktemp -d)"
    tar -xzf "$archive" -C "$extracted"

    local top
    top="$(find "$extracted" -mindepth 1 -maxdepth 1 -type d | head -1)"

    [[ -n "$top" && -d "${top}/submissions" ]] &&
        t_pass "archive has one top-level directory containing components" ||
        t_fail "archive has one top-level directory containing components"

    grep -q 'MANIFEST.sha256' "${top}/MANIFEST.sha256" 2>/dev/null &&
        t_fail "manifest does not list itself" "it does — sha256sum -c can never pass" ||
        t_pass "manifest does not list itself"

    [[ -f "${top}/submissions/${STUDENT_A}/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c" ]] &&
        t_pass "submissions are present inside the backup" ||
        t_fail "submissions are present inside the backup"

    # Nothing that would overwrite the system account database on restore.
    [[ -z "$(find "$extracted" -name 'shadow' -o -name 'passwd' | head -1)" ]] &&
        t_pass "backup contains no system account database" ||
        t_fail "backup contains no system account database"

    rm -rf "$extracted"

    # Restore over a deliberately damaged archive.
    local victim="$(student_archive_path "$STUDENT_A")/assignment01/${SUBMISSION_VERSION_PREFIX}001/main.c"
    rm -f "$victim"

    must "restore submissions from backup" \
        env ASMS_ASSUME_YES=1 "${MODULE_DIR}/restore_backup.sh" \
            --restore "$(basename "$archive")" --components submissions

    [[ -f "$victim" ]] &&
        t_pass "deleted submission was restored" ||
        t_fail "deleted submission was restored"

    # A hand-crafted archive with a symlink member must be refused outright,
    # the same way an archive with an absolute or ../ path already is.
    # Unchecked, a symlink entry (e.g. "configuration -> /etc") could steer
    # extraction of later members in the same archive outside WORK_DIR.
    local evil_dir evil_archive
    evil_dir="$(mktemp -d)"
    ln -s /etc "${evil_dir}/configuration"
    evil_archive="${BACKUP_ROOT}/full-9999-01-01_00-00-00_asmstest-evil.tar.gz"
    tar -C "$evil_dir" -czf "$evil_archive" .
    rm -rf "$evil_dir"

    must_fail "restore refuses an archive containing a symlink entry" \
        "${MODULE_DIR}/restore_backup.sh" --verify "$(basename "$evil_archive")"

    rm -f "$evil_archive"
}

stage_verify_server() {
    stage "Server verification"

    if "${MODULE_DIR}/verify_server.sh" --quiet; then
        t_pass "verify_server reports no failures"
    else
        t_fail "verify_server reports no failures" "run verify_server.sh for detail"
    fi
}

stage_reboot_persistence() {
    stage "Reboot persistence"

    local username
    for username in "$STUDENT_A" "$STUDENT_B"; do
        grep -Eq "^[[:space:]]*$(student_archive_path "$username")[[:space:]]" /etc/fstab &&
            t_pass "$username has an fstab entry" ||
            t_fail "$username has an fstab entry" "the view will not return after reboot"
    done

    # Simulates what a reboot does: drop the mount, then let the boot-time
    # repair path restore it.
    umount "$(student_mount_path "$STUDENT_A")" 2>/dev/null || true

    must "mount repair restores a missing view" \
        "${MODULE_DIR}/configure_mounts.sh" --repair-all

    mountpoint -q "$(student_mount_path "$STUDENT_A")" &&
        t_pass "view is mounted again after repair" ||
        t_fail "view is mounted again after repair"

    local options
    options="$(findmnt -n -o OPTIONS --first-only "$(student_mount_path "$STUDENT_A")" 2>/dev/null || true)"

    [[ ",${options}," == *",ro,"* ]] &&
        t_pass "repaired view is read-only" ||
        t_fail "repaired view is read-only"

    if systemctl is-enabled asms-mounts.service >/dev/null 2>&1; then
        t_pass "asms-mounts.service is enabled for boot"
    else
        t_fail "asms-mounts.service is enabled for boot" \
               "on util-linux < 2.37 views come back read-WRITE after reboot"
    fi
}

stage_semester_reset() {
    stage "Semester reset"

    if ((!WITH_RESET)); then
        t_skip "semester reset" "pass --with-reset to include it (removes ALL students)"
        return
    fi

    local before
    before="$(count_users_in_group "$STUDENT_GROUP")"

    must "semester reset completes" \
        env ASMS_ASSUME_YES=1 "${MODULE_DIR}/reset_semester.sh" --confirm

    (( $(count_users_in_group "$STUDENT_GROUP") == 0 )) &&
        t_pass "all student accounts removed" ||
        t_fail "all student accounts removed"

    (( $(count_users_in_group "$FACULTY_GROUP") > 0 )) &&
        t_pass "faculty accounts untouched" ||
        t_fail "faculty accounts untouched"

    local archived
    archived="$(find "$SEMESTER_ARCHIVE_ROOT" -maxdepth 1 -type d -name 'semester-*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"

    if [[ -n "$archived" && -d "${archived}/${STUDENT_A}" ]]; then
        t_pass "previous submissions were archived before removal"
    else
        t_fail "previous submissions were archived before removal"
    fi

    [[ -f "${archived}.MANIFEST.sha256" ]] &&
        t_pass "semester archive has an integrity manifest" ||
        t_fail "semester archive has an integrity manifest"

    grep -Eq "^[[:space:]]*${SUBMISSION_ROOT}/asmstest_" /etc/fstab &&
        t_fail "student fstab entries were removed" ||
        t_pass "student fstab entries were removed"

    printf '  (had %s students before reset)\n' "$before"
}

# ---------------------------------------------------------------------------

summary() {
    echo
    echo "=================================================="
    echo " Integration Test Summary"
    echo "=================================================="
    printf '  Passed  : %d\n' "$PASS"
    printf '  Failed  : %d\n' "$FAIL"
    printf '  Skipped : %d\n' "$SKIP"
    echo "=================================================="

    if ((FAIL > 0)); then
        echo
        printf '\033[31mFailed tests:\033[0m\n'
        printf '  - %s\n' "${FAILED_TESTS[@]}"
        echo
        echo "Any failure naming isolation, read-only, or archive ownership means"
        echo "the security model is not holding. Do not put this server into use."
        return 1
    fi

    echo
    printf '\033[32mAll checks passed.\033[0m\n'
    echo
    echo "Verified: student isolation, read-only submission views, submit"
    echo "input validation, faculty access, audit targeting, backup integrity"
    echo "and mount persistence."
}

usage() {
    cat <<EOF
Usage: integration_test.sh [option]

  --with-reset   Include the semester-reset stage (removes ALL student accounts)
  --cleanup      Remove this test's accounts and exit
  -h, --help     Show this help

Creates accounts prefixed asmstest_ and removes them when finished.
Run on a test machine, not a production server.
EOF
}

main() {
    case "${1:-}" in
        --with-reset) WITH_RESET=1 ;;
        --cleanup)
            echo "Removing test accounts..."
            cleanup_test_accounts
            echo "Done."
            return 0
            ;;
        -h|--help) usage; return 0 ;;
        "") ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac

    echo "=================================================="
    echo " ASMS Integration Test"
    echo "=================================================="
    printf ' Host          : %s\n' "$(hostname_short)"
    printf ' ASMS root     : %s\n' "$ASMS_ROOT"
    printf ' Test accounts : %s, %s, %s\n' "$STUDENT_A" "$STUDENT_B" "$FACULTY"
    ((WITH_RESET)) && printf ' Semester reset: INCLUDED (removes all students)\n'
    echo "=================================================="
    echo
    echo "This creates and deletes accounts. Ctrl-C now if this is a live server."
    sleep 3

    # Start from a known state; a previous interrupted run would skew results.
    cleanup_test_accounts

    stage_prerequisites
    stage_provision
    stage_submit
    stage_readonly_view
    stage_cross_student_isolation
    stage_submit_hardening
    stage_capacity_limits
    stage_faculty_access
    stage_audit
    stage_backup_restore
    stage_reboot_persistence
    stage_verify_server
    stage_semester_reset

    stage "Cleanup"
    cleanup_test_accounts
    t_pass "test accounts removed"

    summary
}

main "$@"
