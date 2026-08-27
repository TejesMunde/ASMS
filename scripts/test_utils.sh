#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Self-check for the shared library.
#
# Covers the logic that is easy to get silently wrong: account enumeration,
# password generation, validation, and path construction. Run it anywhere
# bash is available -- it stubs getent rather than touching real accounts, so
# it needs no root and creates nothing.
#
#   ./test_utils.sh
#
# The full system test that needs a real server is integration_test.sh.
#

set -Eeuo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SRC_DIR}/.." && pwd)"

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
        printf '  [ OK ] %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s (expected success)\n' "$label"
        FAIL=$((FAIL + 1))
    fi
}

check_fails() {
    local label="$1"; shift

    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s (expected failure, got success)\n' "$label"
        FAIL=$((FAIL + 1))
    else
        printf '  [ OK ] %s\n' "$label"
        PASS=$((PASS + 1))
    fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
#
# alice and bob are students by PRIMARY group (gid 3000) and so do NOT appear
# in the students group member field -- exactly the situation that made every
# enumeration site in the scaffold return nothing.
#
# carol is a student by supplementary membership only.
# dr_smith is faculty. svc_backup shares neither group.

fake_passwd() {
    cat <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
dr_smith:x:1500:1500:Dr Smith:/home/dr_smith:/bin/bash
svc_backup:x:998:998:Backup:/var/lib/backup:/usr/sbin/nologin
alice:x:3001:3000:Alice:/home/alice:/bin/bash
bob:x:3002:3000:Bob:/home/bob:/bin/bash
carol:x:3003:3003:Carol:/home/carol:/bin/bash
EOF
}

fake_group() {
    case "${1:-}" in
        students) echo "students:x:3000:carol" ;;
        faculty)  echo "faculty:x:4000:dr_smith" ;;
        empty)    echo "empty:x:5000:" ;;
        *)        return 2 ;;
    esac
}

# Stub getent so enumeration is exercised without real accounts.
getent() {
    case "$1" in
        passwd) fake_passwd ;;
        group)  fake_group "${2:-}" ;;
        *)      return 2 ;;
    esac
}
export -f getent

# Stub id the same way. `id -nG` reports primary AND supplementary groups,
# which is why user_in_group can rely on it alone.
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
        dr_smith)   groups="dr_smith faculty" ;;
        svc_backup) groups="svc_backup" ;;
        *)          return 1 ;;
    esac

    ((list_groups)) && printf '%s\n' "$groups"
    return 0
}
export -f id

# ---------------------------------------------------------------------------

echo "ASMS shared library self-check"
echo

# shellcheck source=/dev/null
source "${SRC_DIR}/utils.sh"

ASMS_CONFIG_FILE="${REPO_ROOT}/data/config.conf"
load_config

echo "Configuration"
check "config loads STUDENT_GROUP"  "students"        "$STUDENT_GROUP"
check "config loads SUBMISSION_ROOT" "/srv/submissions" "$SUBMISSION_ROOT"
check "config loads mount options"  "bind,ro,nosuid,nodev,noexec" "$STUDENT_MOUNT_OPTIONS"
check "credentials path derived"    "/opt/assignment-server/credentials/student_credentials.csv" \
                                    "$STUDENT_CREDENTIALS"
check "config loads MAX_STUDENT_ARCHIVE_BYTES" "2147483648" "$MAX_STUDENT_ARCHIVE_BYTES"
check "config loads SUBMISSION_MIN_FREE_BYTES" "1073741824" "$SUBMISSION_MIN_FREE_BYTES"
check "config loads DEMO_ACCOUNT_PATTERN"      "^demo[0-9]+$" "$DEMO_ACCOUNT_PATTERN"
check "BACKUP_GPG_KEY_ID defaults empty (signing off)" "" "$BACKUP_GPG_KEY_ID"

echo
echo "Account enumeration (the scaffold's central bug)"

students="$(get_student_users | tr '\n' ' ')"
check "finds primary- AND supplementary-group students" "alice bob carol " "$students"

faculty="$(get_faculty_users | tr '\n' ' ')"
check "finds faculty"                     "dr_smith " "$faculty"
check "student count"                     "3"         "$(count_users_in_group students)"
check "empty group yields no users"       "0"         "$(count_users_in_group empty)"
check "nonexistent group yields no users" "0"         "$(count_users_in_group nosuchgroup)"

# The regression guard: reading only the group member field, as all six
# scaffold enumeration sites did, sees one student out of three.
naive="$(getent group students | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | tr '\n' ' ')"
check "group member field alone is insufficient" "carol " "$naive"

echo
echo "Membership tests"
check_ok    "alice is a student"        is_student_user alice
check_ok    "carol is a student"        is_student_user carol
check_fails "dr_smith is not a student" is_student_user dr_smith
check_fails "svc_backup is not a student" is_student_user svc_backup

echo
echo "Validation"
check_ok    "accepts bt25cse001"          validate_username bt25cse001
check_ok    "accepts demo01"              validate_username demo01
check_fails "rejects root (protected)"    validate_username root
check_fails "rejects leading digit"       validate_username 1student
check_fails "rejects uppercase"           validate_username Student
check_fails "rejects embedded slash"      validate_username "a/b"
check_fails "rejects empty username"      validate_username ""
check_ok    "protected list is honoured"  is_protected_account root

# is_valid_username_format is the format-only half of validate_username,
# split out so remove_students.sh can validate format without losing its own
# specific REFUSED_PROTECTED logging for protected accounts.
check_ok    "format check accepts bt25cse001"     is_valid_username_format bt25cse001
check_ok    "format check accepts root (format only, not protected)" is_valid_username_format root
check_fails "format check rejects embedded slash" is_valid_username_format "a/b"
check_fails "format check rejects uppercase"      is_valid_username_format Student
check_fails "format check rejects empty"          is_valid_username_format ""

check_ok    "accepts assignment01"        validate_assignment_name assignment01
check_ok    "accepts lab-1.2"             validate_assignment_name lab-1.2
check_fails "rejects path traversal"      validate_assignment_name "../etc"
check_fails "rejects slash"               validate_assignment_name "a/b"
check_fails "rejects leading dot"         validate_assignment_name ".hidden"
check_fails "rejects empty assignment"    validate_assignment_name ""

echo
echo "Canonical paths"
check "archive path"     "/srv/submissions/alice"       "$(student_archive_path alice)"
check "mount path"       "/home/alice/submissions"      "$(student_mount_path alice)"
check "assignments path" "/home/alice/assignments"      "$(student_assignments_path alice)"
check "home path"        "/home/alice"                  "$(student_home_path alice)"

echo
echo "Password generation"

password="$(generate_password)"
check "default length honours config" "$PASSWORD_LENGTH" "${#password}"

password="$(generate_password 32)"
check "explicit length" "32" "${#password}"

check_fails "rejects length below minimum" generate_password 4
check_fails "rejects length above maximum" generate_password 999
check_fails "rejects non-numeric length"   generate_password abc

# Only characters from the documented policy set.
password="$(generate_password 128)"
check "charset is restricted" "" "$(printf '%s' "$password" | tr -d 'A-Za-z0-9@#%+=')"

# Distinct outputs. Identical passwords would mean a broken random source.
check "successive passwords differ" "2" \
    "$(printf '%s\n%s\n' "$(generate_password 24)" "$(generate_password 24)" | sort -u | wc -l | tr -d ' ')"

# The regression guard for the SIGPIPE abort: under the same shell options
# the modules use, generating a password must not kill the caller.
(
    set -Eeuo pipefail
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        generate_password >/dev/null
    done
) && sigpipe_ok=0 || sigpipe_ok=$?
check "survives set -Eeuo pipefail (SIGPIPE regression)" "0" "$sigpipe_ok"

echo
echo "======================================"
printf ' Passed: %d\n' "$PASS"
printf ' Failed: %d\n' "$FAIL"
echo "======================================"

((FAIL == 0)) || exit 1

echo "Shared library self-check passed."
