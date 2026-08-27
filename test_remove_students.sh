#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Self-check for remove_students.sh's target resolution and archive
# accounting.
#
# Regression coverage for the bug where requesting removal of a nonexistent
# account with --delete-archive reported "Archives: deleted" even though
# nothing was ever removed -- that line was derived from whether deletion
# was requested, not from what actually happened. Also covers the fix that
# moved destructive confirmation to AFTER invalid/nonexistent IDs are
# identified, instead of before.
#
# getent/id are stubbed (as in test_utils.sh); deconfigure_mount, mountpoint
# and userdel are stubbed so no real mount or account is needed; the archive
# root points at a temp directory. No root required, nothing on this host
# is touched.
#
#   ./test_remove_students.sh
#

set -Eeuo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

check() {
    local label="$1" expected="$2" actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        printf '  [ OK ] %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$label"
        printf '         expected: %q\n' "$expected"
        printf '         actual  : %q\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

check_ok() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [ OK ] %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s (expected success)\n' "$label"; FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# Fixtures -- same shape as test_utils.sh's.
#
# alice and bob are students by PRIMARY group; carol is a student by
# supplementary membership only. dave is a fourth student, used only for the
# roster cross-check below (on the students list but off the class roster,
# and not named to match DEMO_ACCOUNT_PATTERN either). dr_smith is faculty.
# svc_backup is neither.
# ---------------------------------------------------------------------------

fake_passwd() {
    cat <<'EOF'
root:x:0:0:root:/root:/bin/bash
dr_smith:x:1500:1500:Dr Smith:/home/dr_smith:/bin/bash
svc_backup:x:998:998:Backup:/var/lib/backup:/usr/sbin/nologin
alice:x:3001:3000:Alice:/home/alice:/bin/bash
bob:x:3002:3000:Bob:/home/bob:/bin/bash
carol:x:3003:3003:Carol:/home/carol:/bin/bash
dave:x:3004:3000:Dave:/home/dave:/bin/bash
EOF
}

fake_group() {
    case "${1:-}" in
        students) echo "students:x:3000:carol" ;;
        faculty)  echo "faculty:x:4000:dr_smith" ;;
        *)        return 2 ;;
    esac
}

getent() {
    case "$1" in
        passwd) fake_passwd ;;
        group)  fake_group "${2:-}" ;;
        *)      return 2 ;;
    esac
}
export -f getent

id() {
    local list_groups=0
    while [[ "${1:-}" == -* ]]; do
        [[ "$1" == "-nG" || "$1" == "-Gn" ]] && list_groups=1
        shift
    done

    local username="${1:-}"
    local groups=""

    case "$username" in
        root)       groups="root" ;;
        alice)      groups="students" ;;
        bob)        groups="students" ;;
        carol)      groups="carol students" ;;
        dave)       groups="students" ;;
        dr_smith)   groups="dr_smith faculty" ;;
        svc_backup) groups="svc_backup" ;;
        *)          return 1 ;;
    esac

    ((list_groups)) && printf '%s\n' "$groups"
    return 0
}
export -f id

# ---------------------------------------------------------------------------
# Stubs for the parts of remove_student_account() that touch the live
# system. Controlled per scenario via the *_SHOULD_FAIL_FOR variables so a
# specific failure can be forced without a real mount or a real account.
# Defined AFTER sourcing remove_students.sh below, so they replace the real
# deconfigure_mount from configure_mounts.sh and the real userdel/mountpoint
# binaries for the rest of this file.
# ---------------------------------------------------------------------------

DECONFIGURE_MOUNT_SHOULD_FAIL_FOR=""
USERDEL_SHOULD_FAIL_FOR=""

echo "ASMS student removal self-check"
echo

export ASMS_CONFIG_FILE="${SRC_DIR}/data/config.conf"

# require_root lives inside main() now, which this file never calls, so
# sourcing needs no root and runs nothing destructive.
# shellcheck source=remove_students.sh
source "${SRC_DIR}/remove_students.sh"

deconfigure_mount() {
    [[ "$1" == "$DECONFIGURE_MOUNT_SHOULD_FAIL_FOR" ]] && return 1
    return 0
}

mountpoint() {
    # Checked after deconfigure_mount to confirm the view is really gone.
    # Always "not a mountpoint" here: these tests never create a real one.
    return 1
}

userdel() {
    local target="${*: -1}"
    [[ "$target" == "$USERDEL_SHOULD_FAIL_FOR" ]] && return 1
    return 0
}

# Archive root is a temp directory, not /srv/submissions.
ARCHIVE_ROOT="$(mktemp -d)"
SUBMISSION_ROOT="$ARCHIVE_ROOT"

ASMS_ASSUME_YES=1

reset_state() {
    REMOVED=0
    FAILED=0
    ARCHIVES_DELETED=0
    ARCHIVES_KEPT=0
    ARCHIVES_NOT_FOUND=0
    ARCHIVE_DELETE_FAILED=0
    NOTHING_TO_REMOVE=0
    VALID_TARGETS=()
    INVALID_TARGETS=()
    DECONFIGURE_MOUNT_SHOULD_FAIL_FOR=""
    USERDEL_SHOULD_FAIL_FOR=""
    DELETE_ARCHIVE=""
    # find, not `rm -rf "$ARCHIVE_ROOT"/*`: an empty directory leaves that
    # glob unexpanded under this script's nounset/errexit options, and rm
    # would fail on the literal, unmatched "*" path.
    find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

make_archive() {
    # Existence is all these tests check, not mode: plain mkdir avoids a
    # chmod step that some filesystems (e.g. Windows dev boxes) refuse on a
    # freshly created temp-directory entry.
    mkdir -p "${ARCHIVE_ROOT}/$1"
    printf 'work\n' > "${ARCHIVE_ROOT}/$1/file.txt"
}

archive_exists() { [[ -e "${ARCHIVE_ROOT}/$1" ]]; }

# A roster listing alice, bob and carol as real students -- dave is
# deliberately absent, standing in for a hand-provisioned test account with
# a name that does not match DEMO_ACCOUNT_PATTERN either.
ROSTER_CSV="${ARCHIVE_ROOT}.roster.csv"
cat > "$ROSTER_CSV" <<'EOF'
username,full_name
alice,Alice
bob,Bob
carol,Carol
EOF
trap 'rm -rf -- "$ARCHIVE_ROOT" "$ROSTER_CSV"' EXIT

summary_line() {
    # Captures show_summary()'s output for a given field label so tests can
    # assert on the exact administrator-facing text, not just the counters.
    show_summary 2>&1 | grep -F "$1"
}

# ---------------------------------------------------------------------------

echo "Target resolution (read-only, no confirmation, no removal)"

reset_state
resolve_removal_targets "zzz_missing"
check "nonexistent account: not valid"       "0" "${#VALID_TARGETS[@]}"
check "nonexistent account: reported invalid" "1" "${#INVALID_TARGETS[@]}"

reset_state
resolve_removal_targets "root"
check "protected account: not valid" "0" "${#VALID_TARGETS[@]}"
check "protected account: reason recorded" "1" \
    "$(grep -c "protected" <<< "${INVALID_TARGETS[0]:-}")"

reset_state
resolve_removal_targets "Not-A-Valid-Name!"
check "malformed username: not valid" "0" "${#VALID_TARGETS[@]}"

reset_state
resolve_removal_targets "dr_smith"
check "faculty account: not valid (not a student)" "0" "${#VALID_TARGETS[@]}"

reset_state
resolve_removal_targets "alice,zzz_missing,bob"
check "mixed input: valid accounts found"   "2" "${#VALID_TARGETS[@]}"
check "mixed input: invalid accounts found" "1" "${#INVALID_TARGETS[@]}"
check "mixed input: alice recognised" "1" "$(printf '%s\n' "${VALID_TARGETS[@]}" | grep -c '^alice$')"
check "mixed input: bob recognised"   "1" "$(printf '%s\n' "${VALID_TARGETS[@]}" | grep -c '^bob$')"

echo
echo "Demo/test account detection"
echo "(regression: a hand-provisioned test account with a name that does not"
echo " match DEMO_ACCOUNT_PATTERN used to be invisible to this feature)"

reset_state
STUDENT_ROSTER_CSV="/no/such/file"
check_ok "no roster present: off-roster check declines rather than errors" \
    bash -c '! is_off_roster_account alice'

reset_state
STUDENT_ROSTER_CSV="$ROSTER_CSV"
check_ok  "roster present: on-roster account is not off-roster" bash -c '! is_off_roster_account alice'
check_ok  "roster present: off-roster account (dave) is detected" is_off_roster_account dave
check_ok  "demo-pattern account is unaffected by roster presence" is_demo_account demo07

reset_state
STUDENT_ROSTER_CSV="$ROSTER_CSV"
remove_demo >/dev/null 2>&1 || true

# get_student_users() returns alice, bob, carol and dave; only dave is
# off-roster and none match DEMO_ACCOUNT_PATTERN, so REMOVED == 1 is only
# possible if dave alone went through remove_student_account() -- had
# alice/bob/carol been swept in too, this would be higher.
check "remove_demo: off-roster account removed even without pattern match" "1" "$REMOVED"

reset_state
STUDENT_ROSTER_CSV="/no/such/roster.csv"
remove_demo >/dev/null 2>&1 || true
check "remove_demo: with no roster, falls back to pattern only (dave untouched)" "0" "$REMOVED"

echo
echo "Scenario A: nonexistent account + --delete-archive"

reset_state
DELETE_ARCHIVE=1
remove_list "zzz_missing" >/dev/null 2>&1 || true

check "A: account not removed"        "0" "$REMOVED"
check "A: no failures recorded"       "0" "$FAILED"
check "A: nothing counted as deleted" "0" "$ARCHIVES_DELETED"
check "A: flagged as nothing-to-remove" "1" "$NOTHING_TO_REMOVE"
check "A: summary shows zero archives deleted" "1" \
    "$(summary_line 'Archives deleted' | grep -c ' 0$')"

echo
echo "Scenario B: nonexistent account + --keep-archive"

reset_state
DELETE_ARCHIVE=0
remove_list "zzz_missing" >/dev/null 2>&1 || true

check "B: account not removed"      "0" "$REMOVED"
check "B: nothing counted as kept"  "0" "$ARCHIVES_KEPT"
check "B: flagged as nothing-to-remove" "1" "$NOTHING_TO_REMOVE"

echo
echo "Scenario C: mixed valid + nonexistent IDs"

reset_state
DELETE_ARCHIVE=0
remove_list "alice,zzz_missing" >/dev/null 2>&1 || true

check "C: valid account removed"           "1" "$REMOVED"
check "C: not flagged as nothing-to-remove" "0" "$NOTHING_TO_REMOVE"
check "C: nonexistent id caused no failure" "0" "$FAILED"

echo
echo "Scenario D: valid account with an existing archive + --delete-archive"

reset_state
DELETE_ARCHIVE=1
make_archive alice
remove_student_account alice

check "D: account removed"           "1" "$REMOVED"
check "D: exactly one archive deleted" "1" "$ARCHIVES_DELETED"
check_ok "D: archive is actually gone from disk" bash -c "! test -e '${ARCHIVE_ROOT}/alice'"

echo
echo "Scenario E: valid account with no archive + --delete-archive"

reset_state
DELETE_ARCHIVE=1
remove_student_account bob

check "E: account removed"              "1" "$REMOVED"
check "E: nothing counted as deleted"   "0" "$ARCHIVES_DELETED"
check "E: missing archive reported"     "1" "$ARCHIVES_NOT_FOUND"

echo
echo "Scenario F: account-removal failure + --delete-archive"

reset_state
DELETE_ARCHIVE=1
make_archive carol
DECONFIGURE_MOUNT_SHOULD_FAIL_FOR="carol"
remove_student_account carol || true

check "F: account not removed"        "0" "$REMOVED"
check "F: failure recorded"           "1" "$FAILED"
check "F: archive NOT deleted"        "0" "$ARCHIVES_DELETED"
check_ok "F: archive still present on disk" archive_exists carol

echo
echo "Scenario G: multiple valid accounts with mixed archive states"

reset_state
DELETE_ARCHIVE=1
make_archive alice
# bob has no archive.
remove_list "alice,bob" >/dev/null 2>&1 || true

check "G: both accounts removed"        "2" "$REMOVED"
check "G: one archive deleted (alice)"  "1" "$ARCHIVES_DELETED"
check "G: one archive not found (bob)"  "1" "$ARCHIVES_NOT_FOUND"
check "G: no failures"                  "0" "$FAILED"

echo
echo "======================================"
printf ' Passed: %d\n' "$PASS"
printf ' Failed: %d\n' "$FAIL"
echo "======================================"

((FAIL == 0)) || exit 1

echo "Student removal self-check passed."
