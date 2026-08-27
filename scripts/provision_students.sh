#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: provision_students.sh
# Version: 2.0.0
#
# Creates student accounts and their submission environment.
#
# Per student:
#   /home/<student>              0700, student-owned
#   /home/<student>/assignments  0700, student-owned -- where work happens
#   /home/<student>/submissions  read-only bind mount of the archive
#   /srv/submissions/<student>   root-owned archive + per-student ACL
#
# Mounts, archives and ACLs are NOT implemented here. configure_mounts.sh is
# the single authority for all of it and is called for each student. The
# scaffold carried a second copy of that logic in this file, with different
# mount options and a conflicting ownership model.
#
# Usage:
#   provision_students.sh                       interactive menu
#   provision_students.sh --csv FILE
#   provision_students.sh --users alice,bob
#   provision_students.sh --demo PREFIX COUNT
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

# configure_mounts.sh provides the archive, ACL, fstab and mount functions.
# shellcheck source=configure_mounts.sh
source "${ASMS_MODULE_DIR}/configure_mounts.sh"

PROVISIONED=0
FAILED=0

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
#
# Generated passwords are written here and nowhere else. They never reach the
# administrative log, the audit log, or the terminal.

ensure_credential_store() {
    install -d -o root -g root -m "$CREDENTIAL_DIR_MODE" "$CREDENTIAL_DIR"

    if [[ ! -f "$STUDENT_CREDENTIALS" ]]; then
        printf 'username,password,created_at\n' > "$STUDENT_CREDENTIALS"
    fi

    chown root:root "$STUDENT_CREDENTIALS"
    chmod "$CREDENTIAL_FILE_MODE" "$STUDENT_CREDENTIALS"
}

credential_recorded() {
    [[ -f "$STUDENT_CREDENTIALS" ]] &&
        awk -F',' -v u="$1" 'NR > 1 && $1 == u { found = 1 } END { exit !found }' \
            "$STUDENT_CREDENTIALS"
}

record_credential() {
    local username="$1" password="$2"

    credential_recorded "$username" && return 0

    printf '%s,%s,%s\n' "$username" "$password" "$(timestamp)" \
        >> "$STUDENT_CREDENTIALS"

    chmod "$CREDENTIAL_FILE_MODE" "$STUDENT_CREDENTIALS"
}

# ---------------------------------------------------------------------------
# Account creation
# ---------------------------------------------------------------------------

create_account() {
    local username="$1"
    local password="$2"

    # umask 077 for the useradd call only: --create-home otherwise creates
    # the home directory at the distro default mode (often 0755, sometimes
    # populated from /etc/skel) before configure_home() chmods it to 0700
    # afterwards. Students share the students group on this host, so that
    # gap -- however brief -- is a real window for another student to read a
    # freshly created home directory. The subshell keeps the umask change
    # from leaking into the rest of this script.
    (
        umask 077
        useradd \
            --create-home \
            --home-dir "$(student_home_path "$username")" \
            --shell "$DEFAULT_SHELL" \
            --gid "$STUDENT_GROUP" \
            "$username"
    ) || return 1

    # chpasswd reads from stdin, so the password never appears in the process
    # table where any user could see it with ps.
    printf '%s:%s\n' "$username" "$password" | chpasswd || return 1

    # The password just set was generated or supplied by an administrator,
    # not chosen by the student, so a change is mandatory before it can be
    # used again. Failing to set that is a warning, not a reason to roll
    # back an otherwise-successful account creation.
    chage -d 0 "$username" 2>/dev/null ||
        warn "$username: could not force a password change at first login."

    log_action "CREATE_STUDENT" "$username" "SUCCESS"
}

# The home directory is 0700, not the useradd default of 0755.
#
# Students share the students group, so any group-readable path in a home
# directory would be readable by every other student.
configure_home() {
    local username="$1"
    local home assignments

    home="$(student_home_path "$username")"
    assignments="$(student_assignments_path "$username")"

    chown "${username}:${STUDENT_GROUP}" "$home"
    chmod 0700 "$home"

    install -d -o "$username" -g "$STUDENT_GROUP" \
        -m "$STUDENT_ASSIGNMENTS_MODE" "$assignments"
}

install_templates() {
    local username="$1"
    local home template basename_

    home="$(student_home_path "$username")"

    [[ -d "${ASMS_ROOT}/templates" ]] || return 0

    while IFS= read -r -d '' template; do
        basename_="$(basename "$template")"

        install -o "$username" -g "$STUDENT_GROUP" -m 0644 \
            "$template" "${home}/.${basename_}"
    done < <(find "${ASMS_ROOT}/templates" -maxdepth 1 -type f -print0 2>/dev/null)
}

provision_student() {
    local username="$1"
    local supplied_password="${2:-}"
    local password=""

    validate_username "$username" || { FAILED=$((FAILED + 1)); return 1; }

    if user_exists "$username"; then
        if ! is_student_user "$username"; then
            # Adding an existing non-student account to the students group
            # would hand it a submission archive and put it under student
            # audit rules. That needs to be a deliberate admin action.
            error "$username already exists and is not a student account; skipping."
            log_action "PROVISION_STUDENT" "$username" "REFUSED_EXISTING_NON_STUDENT"
            FAILED=$((FAILED + 1))
            return 1
        fi

        info "$username already exists; ensuring environment is correct."
        password="$supplied_password"
    else
        password="${supplied_password:-$(generate_password)}"

        if ! create_account "$username" "$password"; then
            error "Failed to create account: $username"
            log_action "PROVISION_STUDENT" "$username" "FAILED_USERADD"
            FAILED=$((FAILED + 1))
            return 1
        fi

        success "Created student: $username"
    fi

    configure_home "$username"
    install_templates "$username"

    # Archive, ACLs, fstab entry and read-only mount, all from the one module
    # that owns them.
    if ! configure_persistent_mount "$username"; then
        error "$username: submission environment could not be configured."
        log_action "PROVISION_STUDENT" "$username" "FAILED_MOUNT"
        FAILED=$((FAILED + 1))
        return 1
    fi

    [[ -n "$password" ]] && record_credential "$username" "$password"

    log_action "PROVISION_STUDENT" "$username" "SUCCESS"
    PROVISIONED=$((PROVISIONED + 1))
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

# CSV: username[,name[,password]]
#
# Carriage returns are stripped: a roster exported from a spreadsheet on
# Windows arrives CRLF-terminated, and a trailing \r silently becomes part of
# the username, producing an account nobody can log into.
provision_from_csv() {
    local csv="$1"
    local line_number=0
    local username name password

    [[ -f "$csv" ]] || die "CSV file not found: $csv"

    while IFS=',' read -r username name password _rest || [[ -n "${username:-}" ]]; do
        line_number=$((line_number + 1))

        username="${username//$'\r'/}"
        password="${password//$'\r'/}"
        username="${username//[[:space:]]/}"

        [[ -n "$username" ]] || continue
        [[ "$username" == \#* ]] && continue

        if ((line_number == 1)) && [[ "${username,,}" == "username" ]]; then
            continue
        fi

        provision_student "$username" "${password:-}" || true
    done < "$csv"
}

provision_from_list() {
    local input="$1"
    local username

    IFS=',' read -ra requested <<< "$input"

    for username in "${requested[@]}"; do
        username="${username//[[:space:]]/}"
        [[ -n "$username" ]] || continue

        provision_student "$username" || true
    done
}

provision_demo() {
    local prefix="$1"
    local count="$2"
    local index username width

    [[ "$prefix" =~ ^[a-z_][a-z0-9_-]{0,20}$ ]] ||
        die "Invalid demo prefix: $prefix"

    [[ "$count" =~ ^[1-9][0-9]*$ ]] ||
        die "Invalid demo account count: $count"

    ((count <= 1000)) || die "Maximum demo batch is 1000 accounts."

    # Width chosen once so a batch has consistent names; the scaffold decided
    # per-iteration, which split a single batch across two naming schemes.
    if ((count < 100)); then width=2; else width=3; fi

    for ((index = 1; index <= count; index++)); do
        # The scaffold had a bare `username` statement here. That is a command
        # invocation, not an assignment: it failed, and under `set -e` it
        # aborted the whole run on the first account.
        username="$(printf '%s%0*d' "$prefix" "$width" "$index")"

        provision_student "$username" || true
    done
}

# ---------------------------------------------------------------------------
# Post-provisioning
# ---------------------------------------------------------------------------

refresh_audit_rules() {
    local audit_module="${ASMS_MODULE_DIR}/generate_audit.sh"

    [[ -x "$audit_module" ]] || {
        warn "generate_audit.sh is not executable; audit rules were not refreshed."
        return 0
    }

    info "Refreshing student audit rules..."

    if ASMS_ASSUME_YES=1 "$audit_module" --generate >/dev/null 2>&1; then
        success "Audit rules refreshed."
    else
        warn "Audit rules could not be refreshed. Run Generate Audit Rules manually."
    fi
}

show_summary() {
    header "Student Provisioning Complete"

    printf '  %-24s %s\n' "Provisioned"       "$PROVISIONED"
    printf '  %-24s %s\n' "Failed"            "$FAILED"
    printf '  %-24s %s\n' "Student group"     "$STUDENT_GROUP"
    printf '  %-24s %s\n' "Submission root"   "$SUBMISSION_ROOT"
    printf '  %-24s %s\n' "Total students"    "$(count_users_in_group "$STUDENT_GROUP")"
    printf '  %-24s %s\n' "Credentials"       "$STUDENT_CREDENTIALS"
    echo

    warn "Passwords are in the root-only credentials file above."
    warn "Distribute them out of band. A change is required at first login (chage -d 0)."
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

provision_menu() {
    header "Provision Students"

    echo "1. From CSV file"
    echo "2. Enter usernames manually"
    echo "3. Demo/test accounts"
    echo "4. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    case "$choice" in
        1)
            local csv
            csv="$(prompt_value "CSV file path" "${ASMS_ROOT}/data/students.csv")"
            provision_from_csv "$csv"
            ;;
        2)
            local input
            input="$(prompt_value "Student usernames (comma separated)")"
            [[ -n "$input" ]] || die "No usernames supplied."
            provision_from_list "$input"
            ;;
        3)
            local prefix count
            prefix="$(prompt_value "Demo account prefix" "demo")"
            count="$(prompt_value "Number of demo accounts" "2")"
            provision_demo "$prefix" "$count"
            ;;
        4)
            return 0
            ;;
        *)
            die "Invalid choice."
            ;;
    esac
}

usage() {
    cat <<EOF
Usage: provision_students.sh [option]

  --csv FILE            Provision from a CSV roster (username[,name[,password]])
  --users a,b,c         Provision the named accounts
  --demo PREFIX COUNT   Provision COUNT demo accounts named PREFIX01, PREFIX02...
  -h, --help            Show this help

With no option an interactive menu is shown.

Note: remove_students.sh's "Remove demo/test accounts" option finds accounts
matching DEMO_ACCOUNT_PATTERN in config.conf (default: "demo" plus digits)
AND any student-group account not listed in STUDENT_ROSTER_CSV, so a
differently named --demo PREFIX is still found once a roster is uploaded.
--users always works for any name regardless.
EOF
}

main() {
    require_command useradd
    require_command usermod
    require_command chpasswd
    require_command mount
    require_command mountpoint
    require_command findmnt
    require_command setfacl "apt-get install acl"

    ensure_credential_store
    ensure_submission_root

    case "${1:-}" in
        --csv)
            [[ -n "${2:-}" ]] || die "--csv requires a file path."
            provision_from_csv "$2"
            ;;
        --users)
            [[ -n "${2:-}" ]] || die "--users requires a comma-separated list."
            provision_from_list "$2"
            ;;
        --demo)
            [[ -n "${2:-}" && -n "${3:-}" ]] || die "--demo requires PREFIX and COUNT."
            provision_demo "$2" "$3"
            ;;
        -h|--help)
            usage
            return 0
            ;;
        "")
            provision_menu
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac

    ((PROVISIONED > 0)) && refresh_audit_rules

    show_summary

    ((FAILED == 0))
}

main "$@"
