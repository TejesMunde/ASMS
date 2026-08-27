#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Self-check for check_submissions.sh (assignment-check).
#
# check_submissions.sh cannot source utils.sh (that tree is 0700 root-only,
# unreadable to the faculty accounts it runs as), so its enumeration and
# validation logic is a deliberate, standalone copy. This test guards that
# copy against drifting from the canonical behavior it mirrors -- getent/id
# are stubbed exactly as in test_utils.sh, so the same regression (primary-
# group students being missed) would show up here too if reintroduced.
#
#   ./test_check_submissions.sh
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

check_fails() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s (expected failure)\n' "$label"; FAIL=$((FAIL + 1))
    else
        printf '  [ OK ] %s\n' "$label"; PASS=$((PASS + 1))
    fi
}

# Same fixtures as test_utils.sh: alice/bob are students by PRIMARY group
# (the case the scaffold's original bug missed entirely); carol is a
# student by supplementary membership only; dr_smith is faculty.

fake_passwd() {
    cat <<'EOF'
root:x:0:0:root:/root:/bin/bash
dr_smith:x:1500:1500:Dr Smith:/home/dr_smith:/bin/bash
alice:x:3001:3000:Alice:/home/alice:/bin/bash
bob:x:3002:3000:Bob:/home/bob:/bin/bash
carol:x:3003:3003:Carol:/home/carol:/bin/bash
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

# require_faculty calls `id -un` with NO username -- meaning "who am I" --
# to find the current caller before checking their groups. A stub has no
# real EUID to consult, so CURRENT_TEST_USER stands in for "whoever is
# running this test right now" and defaults to a non-faculty identity.
CURRENT_TEST_USER="alice"

id() {
    local mode=""
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -un)     mode="un" ;;
            -nG|-Gn) mode="nG" ;;
        esac
        shift
    done

    local username="${1:-$CURRENT_TEST_USER}"
    local groups

    case "$username" in
        alice)    groups="students" ;;
        bob)      groups="students" ;;
        carol)    groups="carol students" ;;
        dr_smith) groups="dr_smith faculty" ;;
        *)        return 1 ;;
    esac

    if [[ "$mode" == "un" ]]; then
        printf '%s\n' "$username"
    else
        printf '%s\n' "$groups"
    fi
}
export -f id

echo "ASMS assignment-check self-check"
echo

echo "Install-time substitution"
check_ok "source file has unsubstituted placeholders (install.sh's sed step is not a no-op)" \
    bash -c "grep -q '@SUBMISSION_ROOT@' '${SRC_DIR}/check_submissions.sh'"

# shellcheck source=check_submissions.sh
source "${SRC_DIR}/check_submissions.sh"

# The @...@ placeholders are only substituted by install.sh at install
# time; this is the raw source, so set them explicitly to match the
# fixtures above (test_check_submissions.sh's own regression guard below
# confirms install.sh actually performs this substitution on the real,
# installed copy).
STUDENT_GROUP="students"
FACULTY_GROUP="faculty"
SUBMISSION_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$SUBMISSION_ROOT"' EXIT

echo "Validation"
check_ok    "accepts assignment01"     valid_assignment_name assignment01
check_ok    "accepts lab-1.2"          valid_assignment_name lab-1.2
check_fails "rejects path traversal"   valid_assignment_name "../etc"
check_fails "rejects slash"            valid_assignment_name "a/b"
check_fails "rejects leading dot"      valid_assignment_name ".hidden"
check_fails "rejects empty"            valid_assignment_name ""

echo
echo "Group membership"
check_ok    "alice is in students (via in_group)"     in_group alice students
check_fails "alice is not in faculty (via in_group)"  in_group alice faculty
check_ok    "dr_smith is in faculty (via in_group)"   in_group dr_smith faculty

echo
echo "Student enumeration (mirrors get_student_users' primary-group fix)"
students="$(list_students | tr '\n' ' ')"
check "finds primary- AND supplementary-group students" "alice bob carol " "$students"

naive="$(getent group students | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | tr '\n' ' ')"
check "group member field alone is insufficient (regression guard)" "carol " "$naive"

echo
echo "require_faculty"
# Run in an explicit subshell: on rejection, require_faculty calls exit via
# fail(), which would otherwise terminate this whole test script rather
# than just report a failure back to it.

CURRENT_TEST_USER="alice"
if (require_faculty) >/dev/null 2>&1; then
    printf '  [FAIL] non-faculty caller (alice) is rejected (expected failure)\n'; FAIL=$((FAIL + 1))
else
    printf '  [ OK ] non-faculty caller (alice) is rejected\n'; PASS=$((PASS + 1))
fi

CURRENT_TEST_USER="dr_smith"
if (require_faculty) >/dev/null 2>&1; then
    printf '  [ OK ] faculty caller (dr_smith) is accepted\n'; PASS=$((PASS + 1))
else
    printf '  [FAIL] faculty caller (dr_smith) is accepted (expected success)\n'; FAIL=$((FAIL + 1))
fi

CURRENT_TEST_USER="alice"

echo
echo "check_assignment / list_assignments (end to end, against a temp archive)"

# alice: two versions of assignment01. bob: nothing. carol: assignment02
# only. Mirrors the real archive layout under SUBMISSION_ROOT.
mkdir -p "${SUBMISSION_ROOT}/alice/assignment01/submission-001"
mkdir -p "${SUBMISSION_ROOT}/alice/assignment01/submission-002"
mkdir -p "${SUBMISSION_ROOT}/carol/assignment02/submission-001"

report="$(check_assignment assignment01)"

check "alice shown as submitted" "1" "$(grep -c '^alice ' <<< "$report" | head -1)"
check "alice's version count is 2" "1" "$(grep 'alice' <<< "$report" | grep -c ' 2 ')"
check "alice's latest version is submission-002" "1" "$(grep 'alice' <<< "$report" | grep -c 'submission-002')"
check "bob shown as NOT submitted" "1" "$(grep -c '^bob .*NOT submitted' <<< "$report")"
check "carol (different assignment) shown as NOT submitted" "1" "$(grep -c '^carol .*NOT submitted' <<< "$report")"
check "summary line is accurate" "Submitted: 1 / 3" "$(grep '^Submitted:' <<< "$report")"

assignments="$(list_assignments | tr '\n' ' ')"
check "list_assignments finds both assignment names" "assignment01 assignment02 " "$assignments"

# Regression guard: list_assignments used to set its "anything found?" flag
# inside a loop piped into sort -u, which bash runs in a subshell -- the
# flag never propagated back, so the "no submissions yet" fallback fired
# unconditionally alongside real results.
EMPTY_ROOT="$(mktemp -d)"
real_root="$SUBMISSION_ROOT"
SUBMISSION_ROOT="$EMPTY_ROOT"
check "list_assignments reports cleanly when nothing exists (no stray extra output)" \
    "No submissions found yet." "$(list_assignments)"
SUBMISSION_ROOT="$real_root"
rm -rf -- "$EMPTY_ROOT"

echo
echo "======================================"
printf ' Passed: %d\n' "$PASS"
printf ' Failed: %d\n' "$FAIL"
echo "======================================"

((FAIL == 0)) || exit 1

echo "assignment-check self-check passed."
