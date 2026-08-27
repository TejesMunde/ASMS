#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: utils.sh
# Version: 2.0.0
#
# The shared library. Every module sources this and nothing else duplicates
# what lives here.
#
# Usage:
#   source "${MODULE_DIR}/utils.sh"
#   require_root
#   load_config
#
# This library deliberately does NOT set shell options. Callers set their own
# `set -Eeuo pipefail`; a sourced library that changes the caller's shell
# state is a source of action at a distance.
#

# ---------------------------------------------------------------------------
# Locating the installation
# ---------------------------------------------------------------------------
#
# Derived from this file's own location rather than hardcoded, so an
# installation under a non-default --prefix works without editing modules.

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASMS_ROOT="${ASMS_ROOT:-$(cd -- "${ASMS_MODULE_DIR}/.." && pwd)}"
ASMS_CONFIG_FILE="${ASMS_CONFIG_FILE:-${ASMS_ROOT}/data/config.conf}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
#
# Colour only when stdout is a terminal, so redirected output and log
# captures stay clean.

if [[ -t 1 ]]; then
    _red="\033[31m"; _green="\033[32m"; _yellow="\033[33m"
    _blue="\033[34m"; _reset="\033[0m"
else
    _red=""; _green=""; _yellow=""; _blue=""; _reset=""
fi

info()    { echo -e "${_blue}[INFO]${_reset} $*"; }
success() { echo -e "${_green}[ OK ]${_reset} $*"; }
warn()    { echo -e "${_yellow}[WARN]${_reset} $*"; }
error()   { echo -e "${_red}[FAIL]${_reset} $*" >&2; }

divider() {
    printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '='
}

header() {
    echo
    divider
    echo "$1"
    divider
}

die() {
    error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# Defaults are applied AFTER sourcing, so a configuration file that omits a
# key still yields a working value, and a key that IS set is never silently
# overridden by a module afterwards.
#
# Modules must not re-apply their own `${VAR:-default}` after load_config.
# Doing so is what made CREDENTIAL_DIR unconfigurable in the scaffold.

load_config() {
    if [[ -f "$ASMS_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ASMS_CONFIG_FILE"
    else
        error "Missing configuration: $ASMS_CONFIG_FILE"
        error "Run install.sh to create it."
        return 1
    fi

    STUDENT_GROUP="${STUDENT_GROUP:-students}"
    FACULTY_GROUP="${FACULTY_GROUP:-faculty}"

    SUBMISSION_ROOT="${SUBMISSION_ROOT:-/srv/submissions}"
    STUDENT_HOME_ROOT="${STUDENT_HOME_ROOT:-/home}"
    BACKUP_ROOT="${BACKUP_ROOT:-${ASMS_ROOT}/backups}"
    SEMESTER_ARCHIVE_ROOT="${SEMESTER_ARCHIVE_ROOT:-${ASMS_ROOT}/archive/semesters}"
    CREDENTIAL_DIR="${CREDENTIAL_DIR:-${ASMS_ROOT}/credentials}"

    DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"
    PASSWORD_LENGTH="${PASSWORD_LENGTH:-16}"
    PROTECTED_ACCOUNTS="${PROTECTED_ACCOUNTS:-root}"

    SUBMISSION_ROOT_MODE="${SUBMISSION_ROOT_MODE:-0711}"
    STUDENT_ARCHIVE_MODE="${STUDENT_ARCHIVE_MODE:-0750}"
    STUDENT_ASSIGNMENTS_MODE="${STUDENT_ASSIGNMENTS_MODE:-0700}"
    CREDENTIAL_DIR_MODE="${CREDENTIAL_DIR_MODE:-0700}"
    CREDENTIAL_FILE_MODE="${CREDENTIAL_FILE_MODE:-0600}"

    STUDENT_MOUNT_OPTIONS="${STUDENT_MOUNT_OPTIONS:-bind,ro,nosuid,nodev,noexec}"

    SUBMIT_BIN="${SUBMIT_BIN:-/usr/local/bin/submit}"
    SUBMIT_STORE_HELPER="${SUBMIT_STORE_HELPER:-/usr/local/libexec/asms-store}"
    SUBMISSION_VERSION_PREFIX="${SUBMISSION_VERSION_PREFIX:-submission-}"
    MAX_SUBMISSION_BYTES="${MAX_SUBMISSION_BYTES:-104857600}"
    MAX_SUBMISSION_FILES="${MAX_SUBMISSION_FILES:-2000}"

    # Aggregate limits: see data/config.conf for why per-submission limits
    # alone do not bound total disk use. Defaults here match the shipped
    # config.conf so an installation with an older config file (install.sh
    # never overwrites it) still gets the protection.
    MAX_STUDENT_ARCHIVE_BYTES="${MAX_STUDENT_ARCHIVE_BYTES:-2147483648}"
    SUBMISSION_MIN_FREE_BYTES="${SUBMISSION_MIN_FREE_BYTES:-1073741824}"

    BACKUP_GPG_KEY_ID="${BACKUP_GPG_KEY_ID:-}"
    DEMO_ACCOUNT_PATTERN="${DEMO_ACCOUNT_PATTERN:-^demo[0-9]+$}"
    STUDENT_ROSTER_CSV="${STUDENT_ROSTER_CSV:-${ASMS_ROOT}/data/students.csv}"

    AUDIT_RULE_FILE="${AUDIT_RULE_FILE:-/etc/audit/rules.d/50-student-commands.rules}"
    AUDIT_KEY_PREFIX="${AUDIT_KEY_PREFIX:-student_cmd}"
    AUDIT_COMMANDS="${AUDIT_COMMANDS:-rm cp mv chmod chown git python3 sudo su submit}"

    STUDENT_CREDENTIALS="${CREDENTIAL_DIR}/student_credentials.csv"
    FACULTY_CREDENTIALS="${CREDENTIAL_DIR}/faculty_credentials.csv"

    ASMS_CONFIG_LOADED=1
    return 0
}

# For modules that may be sourced by another module which already loaded the
# configuration. Avoids re-reading the file without forcing every caller to
# track whether it happened.
ensure_config() {
    [[ "${ASMS_CONFIG_LOADED:-0}" == "1" ]] || load_config
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_root() {
    [[ $EUID -eq 0 ]] || die "This module must be run as root (use sudo)."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1${2:+ (install: $2)}"
}

user_exists()  { id "$1" >/dev/null 2>&1; }
group_exists() { getent group "$1" >/dev/null 2>&1; }
cmd_exists()   { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------
#
# Set ASMS_ASSUME_YES=1 to answer every prompt affirmatively. This is what
# lets one module drive another non-interactively -- reset_semester.sh
# reusing remove_students.sh instead of reimplementing account removal.
#
# It is never enabled by default: destructive operations must be an explicit
# choice, whether a human types it or a calling module sets it.

confirm() {
    local prompt="$1"
    local answer

    if [[ "${ASMS_ASSUME_YES:-0}" == "1" ]]; then
        info "${prompt} [auto-yes]"
        return 0
    fi

    # No terminal and no explicit assume-yes: refuse rather than hang.
    # The scaffold's reset_semester.sh called configure_mounts.sh with stdout
    # redirected, where it blocked forever on an invisible prompt.
    if [[ ! -t 0 ]]; then
        error "${prompt}"
        error "No terminal available and ASMS_ASSUME_YES is not set; refusing."
        return 1
    fi

    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

prompt_value() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ ! -t 0 ]]; then
        printf '%s' "$default"
        return 0
    fi

    read -r -p "${prompt}${default:+ [$default]}: " answer
    printf '%s' "${answer:-$default}"
}

# ---------------------------------------------------------------------------
# Account enumeration -- THE canonical implementation
# ---------------------------------------------------------------------------
#
# Reading the member field of /etc/group is NOT sufficient and is the single
# most damaging bug in the original scaffold.
#
# Students are created with STUDENT_GROUP as their PRIMARY group. A user's
# primary group membership is recorded in their passwd entry, not in the
# group's member list, so `getent group students` returns an EMPTY member
# field however many students exist. Every module that enumerated that way
# silently operated on nothing: no audit rules, no mount verification, and
# "remove all students" removing nobody.
#
# This function matches both primary GID and supplementary membership, so it
# is correct regardless of how an account was created.

get_users_in_group() {
    local group="$1"
    local gid

    gid="$(getent group "$group" 2>/dev/null | cut -d: -f3)"

    [[ -n "$gid" ]] || return 0

    {
        # Primary members: passwd entries whose GID field matches.
        getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'

        # Supplementary members: the group's member field.
        getent group "$group" | cut -d: -f4 | tr ',' '\n'
    } |
        sed '/^[[:space:]]*$/d' |
        sort -u
}

get_student_users() { get_users_in_group "${STUDENT_GROUP:-students}"; }
get_faculty_users() { get_users_in_group "${FACULTY_GROUP:-faculty}"; }

count_users_in_group() {
    get_users_in_group "$1" | awk 'NF { n++ } END { print n + 0 }'
}

# Single-account membership test. Covers primary and supplementary
# membership because `id -nG` reports both.
user_in_group() {
    local username="$1" group="$2"

    id "$username" >/dev/null 2>&1 || return 1

    id -nG "$username" 2>/dev/null |
        tr ' ' '\n' |
        grep -Fxq "$group"
}

is_student_user() { user_in_group "$1" "${STUDENT_GROUP:-students}"; }
is_faculty_user() { user_in_group "$1" "${FACULTY_GROUP:-faculty}"; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Accounts no module may ever remove or modify, whatever group they are in.
is_protected_account() {
    local username="$1"
    local protected

    for protected in $PROTECTED_ACCOUNTS; do
        [[ "$username" == "$protected" ]] && return 0
    done

    return 1
}

# Linux username format only, split out from validate_username so a caller
# that needs its own error/log message for a protected account (as
# remove_students.sh does) can still get the canonical format check rather
# than growing a second copy of this regex.
is_valid_username_format() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# Linux username rules, plus a refusal to touch protected accounts.
validate_username() {
    local username="$1"

    is_valid_username_format "$username" || {
        error "Invalid username: '${username}'"
        error "Use lowercase letters, digits, underscore and hyphen; max 32 characters."
        return 1
    }

    if is_protected_account "$username"; then
        error "Refusing to operate on protected account: $username"
        return 1
    fi

    return 0
}

# Assignment identifiers become directory names inside the archive, so they
# must not contain a path separator, start with a dot, or be a traversal.
validate_assignment_name() {
    local assignment="$1"

    [[ "$assignment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
        error "Invalid assignment name: '${assignment}'"
        error "Use letters, digits, dot, underscore and hyphen; must not start with a dot."
        return 1
    }

    [[ "$assignment" != *".."* ]] || {
        error "Invalid assignment name: '${assignment}'"
        return 1
    }

    return 0
}

# ---------------------------------------------------------------------------
# Canonical paths
# ---------------------------------------------------------------------------
#
# Every module builds these the same way. Mount, provisioning, removal,
# submit and verification must agree on them exactly, or a student's view
# silently stops matching their archive.

student_home_path()        { printf '%s/%s' "$STUDENT_HOME_ROOT" "$1"; }
student_assignments_path() { printf '%s/%s/assignments' "$STUDENT_HOME_ROOT" "$1"; }
student_mount_path()       { printf '%s/%s/submissions' "$STUDENT_HOME_ROOT" "$1"; }
student_archive_path()     { printf '%s/%s' "$SUBMISSION_ROOT" "$1"; }

# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------
#
# The one implementation lives in generate_password.sh and is sourced here so
# every module shares it. The scaffold had three separate implementations,
# two of which aborted their caller under `set -o pipefail`.

if [[ -f "${ASMS_MODULE_DIR}/generate_password.sh" ]]; then
    # shellcheck disable=SC1091
    source "${ASMS_MODULE_DIR}/generate_password.sh"
fi

# ---------------------------------------------------------------------------
# System information
# ---------------------------------------------------------------------------

timestamp()      { date '+%Y-%m-%d %H:%M:%S %Z'; }
timestamp_id()   { date '+%Y-%m-%d_%H-%M-%S'; }
hostname_short() { hostname -s 2>/dev/null || hostname; }
kernel_version() { uname -r; }

os_description() {
    if [[ -f /etc/os-release ]]; then
        # Subshell: /etc/os-release sets NAME, VERSION and friends, which
        # would otherwise leak into the caller's namespace.
        ( . /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}" )
    else
        printf 'unknown'
    fi
}
