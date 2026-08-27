#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: generate_password.sh
# Version: 2.0.0
#
# The single password generator for ASMS. Dual-purpose:
#
#   sourced as a library (utils.sh does this):
#       password="$(generate_password)"
#       password="$(generate_password 24)"
#
#   run as a command:
#       generate_password.sh
#       generate_password.sh 24
#
# Generated passwords are returned on stdout and never written to logs,
# audit records, or any file by this module. Only the provisioning modules
# persist them, into a root-only 0600 credentials file.
#

# Password character set. Excludes quotes, backslash and shell
# metacharacters so a generated password cannot break a CSV field or a
# chpasswd line.
ASMS_PASSWORD_CHARSET='A-Za-z0-9@#%+='

ASMS_PASSWORD_MIN=12
ASMS_PASSWORD_MAX=128

validate_password_length() {
    local length="$1"

    [[ "$length" =~ ^[0-9]+$ ]] || {
        echo "ERROR: Password length must be an integer." >&2
        return 1
    }

    if ((length < ASMS_PASSWORD_MIN || length > ASMS_PASSWORD_MAX)); then
        echo "ERROR: Password length must be between ${ASMS_PASSWORD_MIN} and ${ASMS_PASSWORD_MAX}." >&2
        return 1
    fi

    return 0
}

generate_password() {
    local length="${1:-${PASSWORD_LENGTH:-16}}"

    validate_password_length "$length" || return 1

    local password=""
    local attempts=0

    # Pipeline order matters. `head` must be the PRODUCER:
    #
    #   head -c N /dev/urandom | tr -dc SET      correct
    #   tr -dc SET < /dev/urandom | head -c N    aborts the caller
    #
    # In the second form head exits as soon as it has N bytes, tr is killed
    # by SIGPIPE, and the pipeline returns 141. Under `set -o pipefail` that
    # fails the command substitution, and under `set -e` it terminates the
    # calling script. Two of the scaffold's three generators were written
    # that way, which is why faculty provisioning died on its first account.
    #
    # With head as the producer, tr reads to EOF and no signal is raised.
    #
    # /dev/urandom is the cryptographic random source. Filtering bytes to a
    # 67-character set keeps roughly a quarter of them, so 8 bytes per
    # requested character makes a second pass very unlikely.
    while ((${#password} < length)); do
        if ((++attempts > 10)); then
            echo "ERROR: Could not gather sufficient random data." >&2
            return 1
        fi

        password+="$(
            head -c "$((length * 8))" /dev/urandom |
                LC_ALL=C tr -dc "$ASMS_PASSWORD_CHARSET"
        )"
    done

    printf '%s\n' "${password:0:length}"
}

# ---------------------------------------------------------------------------
# Command-line entry point
# ---------------------------------------------------------------------------

_generate_password_usage() {
    cat <<EOF
Usage:
  $(basename "$0")            Generate one password of the configured length
  $(basename "$0") LENGTH     Generate one password of LENGTH characters

Password policy:
  Length     ${ASMS_PASSWORD_MIN}-${ASMS_PASSWORD_MAX} (default: \${PASSWORD_LENGTH:-16})
  Characters A-Z a-z 0-9 @ # % + =
EOF
}

_generate_password_main() {
    case "${1:-}" in
        -h|--help)
            _generate_password_usage
            return 0
            ;;
    esac

    if (($# > 1)); then
        _generate_password_usage >&2
        return 2
    fi

    generate_password "${1:-${PASSWORD_LENGTH:-16}}"
}

# Run only when executed directly. When sourced -- which is how utils.sh
# shares this implementation -- defining the functions is the entire job.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail

    # Standalone use still honours the configured default length.
    _gp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "${_gp_root}/data/config.conf" ]]; then
        # shellcheck disable=SC1091
        source "${_gp_root}/data/config.conf"
    fi

    _generate_password_main "$@"
fi
