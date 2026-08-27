#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# assignment-check -- per-assignment submission status across the class
# Version: 2.0.0
#
# Usage:
#   assignment-check ASSIGNMENT           who has submitted ASSIGNMENT
#   assignment-check --list-assignments   distinct assignment names seen so far
#   assignment-check -h | --help
#
# Runs as the calling user -- not as root, not setuid. Unlike submit, it
# needs no privilege beyond what a faculty account already has: the
# g:faculty:rX ACL on every student archive already grants read and
# traverse, and the default ACL applied at submission time extends that to
# every assignment and version underneath. Faculty could already do this by
# hand, one student at a time; this just automates it across the roster.
#
# Self-contained on purpose. Every other module sources utils.sh/logger.sh
# from the installed tree, but that tree is 0700 root-only -- unreadable to
# the faculty accounts this tool exists for. SUBMISSION_ROOT, STUDENT_GROUP
# and FACULTY_GROUP are compiled in by install.sh instead, the same way
# asms-submit.c's constants are, via @PLACEHOLDER@ substitution. The
# enumeration logic below deliberately mirrors get_student_users() in
# utils.sh rather than sourcing it: if that function's matching logic ever
# changes (it exists specifically because students are provisioned with
# STUDENT_GROUP as their PRIMARY group, which getent group's member field
# alone misses), mirror the change here too.
#
# @SUBMISSION_ROOT@, @STUDENT_GROUP@, @FACULTY_GROUP@ are substituted by
# install.sh.
#

set -Eeuo pipefail

SUBMISSION_ROOT="@SUBMISSION_ROOT@"
STUDENT_GROUP="@STUDENT_GROUP@"
FACULTY_GROUP="@FACULTY_GROUP@"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") ASSIGNMENT           List every student's submission status for ASSIGNMENT
  $(basename "$0") --list-assignments   List distinct assignment names seen across the class
  $(basename "$0") -h, --help           Show this help

Read-only; changes nothing. Usable by any member of the '${FACULTY_GROUP}'
group, and by root.
EOF
}

fail() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

in_group() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$2"
}

require_faculty() {
    [[ $EUID -eq 0 ]] && return 0
    in_group "$(id -un)" "$FACULTY_GROUP" ||
        fail "you must be a member of '${FACULTY_GROUP}' to run this."
}

# Same character set as validate_assignment_name() in utils.sh: letters,
# digits, dot, underscore, hyphen, no leading dot, no "..". An assignment
# name here is about to become part of a filesystem path built from user
# input, even though the read it permits is already bounded by the caller's
# own ACLs.
valid_assignment_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [[ "$1" != *".."* ]]
}

# Mirrors get_student_users() in utils.sh. Matches both primary GID and
# supplementary membership so a student whose primary group is
# STUDENT_GROUP (the normal case) is not missed.
list_students() {
    local gid
    gid="$(getent group "$STUDENT_GROUP" 2>/dev/null | cut -d: -f3)"
    [[ -n "$gid" ]] || return 0

    {
        getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'
        getent group "$STUDENT_GROUP" | cut -d: -f4 | tr ',' '\n'
    } | sed '/^[[:space:]]*$/d' | sort -u
}

check_assignment() {
    local assignment="$1"
    local student archive submitted=0 total=0 versions latest

    printf '%-18s %-14s %-10s %s\n' "STUDENT" "STATUS" "VERSIONS" "LATEST"
    printf '%-18s %-14s %-10s %s\n' "-------" "------" "--------" "------"

    while IFS= read -r student; do
        [[ -n "$student" ]] || continue
        total=$((total + 1))
        archive="${SUBMISSION_ROOT}/${student}/${assignment}"

        if [[ -d "$archive" ]]; then
            versions="$(find "$archive" -mindepth 1 -maxdepth 1 -type d \
                -name 'submission-*' 2>/dev/null | wc -l)"
            latest="$(find "$archive" -mindepth 1 -maxdepth 1 -type d \
                -name 'submission-*' -printf '%f\n' 2>/dev/null | sort | tail -1)"
            printf '%-18s %-14s %-10s %s\n' "$student" "submitted" "$versions" "${latest:-?}"
            submitted=$((submitted + 1))
        else
            printf '%-18s %-14s %-10s %s\n' "$student" "NOT submitted" "-" "-"
        fi
    done < <(list_students)

    echo
    printf 'Submitted: %d / %d\n' "$submitted" "$total"
}

list_assignments() {
    local student archive output

    # Captured via command substitution rather than a flag set inside the
    # loop: the loop is the left side of a pipe into sort -u, so bash runs
    # it in a subshell -- a flag assigned there would never be visible out
    # here.
    output="$(
        while IFS= read -r student; do
            [[ -n "$student" ]] || continue
            archive="${SUBMISSION_ROOT}/${student}"
            [[ -d "$archive" ]] || continue
            find "$archive" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
        done < <(list_students) | sort -u
    )"

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    else
        echo "No submissions found yet."
    fi
}

main() {
    require_faculty

    # find can internally chdir during traversal and then restore its
    # starting directory when done; if the caller's cwd is somewhere find
    # itself cannot get back into (observed via sudo -u from a directory the
    # target user has no access to), that restore fails, find exits
    # non-zero despite having produced correct output, and pipefail would
    # otherwise kill this script partway through the roster. / is always
    # traversable, so anchoring here removes the caller's cwd from the
    # equation entirely. Same reasoning as asms-submit.c's chdir("/").
    cd / || fail "cannot change to a safe working directory"

    case "${1:-}" in
        -h|--help)
            usage
            ;;
        --list-assignments)
            list_assignments
            ;;
        "")
            usage >&2
            exit 2
            ;;
        *)
            valid_assignment_name "$1" ||
                fail "invalid assignment name: '$1'"
            check_assignment "$1"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
