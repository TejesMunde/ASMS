#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: logger.sh
# Version: 2.0.0
#
# Structured administrative logging.
#
# Usage:
#   source "${MODULE_DIR}/logger.sh"
#   log_info "message"
#   log_action "PROVISION_STUDENT" "bt25cse001" "SUCCESS"
#
# Logs record WHAT an administrator did and to WHICH account. They never
# record passwords: provisioning modules pass generated credentials straight
# to chpasswd and the root-only credentials file, never through this module.
#
# Like utils.sh this is a library and does not set shell options.
#

# Administrative logs name accounts and actions, so they are root-only.
ASMS_LOG_DIR="${ASMS_LOG_DIR:-${ASMS_ROOT:-/opt/assignment-server}/logs}"
ASMS_LOG_MODE="${ASMS_LOG_MODE:-0600}"

# Resolved per write rather than at source time, so a long-running admin
# session rolls over correctly at a month boundary.
_logger_current_file() {
    printf '%s/%s.log' "$ASMS_LOG_DIR" "$(date +%Y-%m)"
}

_logger_write() {
    local level="$1"
    shift

    local log_file
    log_file="$(_logger_current_file)"

    # Logging must never interfere with the operation being logged, and must
    # never write diagnostics to stderr where a caller could mistake them for
    # the module's own output. If the log is unwritable, carry on silently.
    if [[ ! -f "$log_file" ]]; then
        mkdir -p "$ASMS_LOG_DIR" 2>/dev/null || return 0
        touch "$log_file" 2>/dev/null || return 0
        chmod "$ASMS_LOG_MODE" "$log_file" 2>/dev/null || return 0
    fi

    # Attribute to the human behind sudo, not to root. An audit trail that
    # says every action was taken by "root" identifies nobody.
    printf '%s | %-7s | %s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$level" \
        "${SUDO_USER:-${USER:-unknown}}" \
        "$*" >> "$log_file"
}

log_info()    { _logger_write "INFO"    "$*"; }
log_success() { _logger_write "SUCCESS" "$*"; }
log_warn()    { _logger_write "WARNING" "$*"; }
log_error()   { _logger_write "ERROR"   "$*"; }

# Structured administrative event:
#   log_action "PROVISION_STUDENT" "bt25cse001" "SUCCESS"
log_action() {
    _logger_write "ACTION" \
        "action=${1:-UNKNOWN} target=${2:-N/A} status=${3:-UNKNOWN}"
}

# Record a module failure with its exit status.
log_failure() {
    log_action "${1:-UNKNOWN}" "${2:-N/A}" "FAILED(rc=${3:-1})"
}

log_session_start() {
    _logger_write "SESSION" "start module=${1:-unknown} pid=$$"
}

log_session_end() {
    _logger_write "SESSION" "end module=${1:-unknown} status=${2:-SUCCESS} pid=$$"
}

# Key=value event:
#   log_event "student" "bt25cse001" "assignment" "assignment01"
log_event() {
    local output=""

    while (($# >= 2)); do
        output+="${1}=${2} "
        shift 2
    done

    _logger_write "EVENT" "${output% }"
}

# Path of the active log file.
log_file_path() { _logger_current_file; }
