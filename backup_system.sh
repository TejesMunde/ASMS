#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: backup_system.sh
# Version: 2.0.0
#
# Creates versioned backups of ASMS configuration and data.
#
# ONE format, always compressed:
#
#   /opt/assignment-server/backups/
#   ├── full-2026-08-11_09-30-00_srv01.tar.gz
#   └── full-2026-08-11_09-30-00_srv01.tar.gz.sha256
#
# and inside the archive, under a single top-level directory:
#
#   full-2026-08-11_09-30-00_srv01/
#   ├── backup-info.txt
#   ├── MANIFEST.sha256        hashes of the data files, NOT of itself
#   ├── configuration/
#   ├── credentials/
#   ├── submissions/
#   └── logs/
#
# The manifest is built into a temporary file OUTSIDE the staging directory
# and moved in afterwards, so it cannot list itself. The scaffold generated a
# manifest, then regenerated it in place after the file already existed: the
# shell truncated it before find ran, the manifest recorded the hash of an
# empty file for itself, and `sha256sum -c` could never pass. Backups looked
# fine and were unverifiable.
#
# Usage:
#   backup_system.sh                  interactive menu
#   backup_system.sh --full
#   backup_system.sh --config
#   backup_system.sh --submissions
#   backup_system.sh --credentials
#   backup_system.sh --list
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

TIMESTAMP="$(timestamp_id)"
HOST="$(hostname_short)"

STAGING=""
FINAL_ARCHIVE=""

cleanup() {
    [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf --one-file-system -- "$STAGING"
    return 0
}
trap cleanup EXIT

ensure_backup_root() {
    install -d -o root -g root -m 0700 "$BACKUP_ROOT"
}

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

copy_if_present() {
    local source="$1" destination="$2"

    [[ -e "$source" ]] || return 0

    install -d -o root -g root -m 0700 "$(dirname "$destination")"
    cp -a "$source" "$destination"
}

copy_configuration() {
    local target="${STAGING}/configuration"

    install -d -o root -g root -m 0700 "$target"

    copy_if_present "${ASMS_ROOT}/VERSION"           "${target}/VERSION"
    copy_if_present "${ASMS_ROOT}/README.md"         "${target}/README.md"
    copy_if_present "${ASMS_ROOT}/CHANGELOG.md"      "${target}/CHANGELOG.md"
    copy_if_present "${ASMS_ROOT}/data/config.conf"  "${target}/config.conf"
    copy_if_present "${ASMS_ROOT}/data/students.csv" "${target}/students.csv"
    copy_if_present "${ASMS_ROOT}/data/faculty.csv"  "${target}/faculty.csv"

    # The ASMS code itself, so a backup can rebuild a lost installation.
    install -d -o root -g root -m 0700 "${target}/assignment-server"

    copy_if_present "${ASMS_ROOT}/modules"          "${target}/assignment-server/modules"
    copy_if_present "${ASMS_ROOT}/assignment-admin" "${target}/assignment-server/assignment-admin"
    copy_if_present "${ASMS_ROOT}/templates"        "${target}/assignment-server/templates"

    # System configuration owned by ASMS. Nothing else from /etc is captured:
    # a backup that contains /etc/passwd invites a restore that writes it.
    install -d -o root -g root -m 0700 "${target}/system"

    copy_if_present "$AUDIT_RULE_FILE" \
        "${target}/system/$(basename "$AUDIT_RULE_FILE")"

    # Only the ASMS bind-mount lines from fstab, never the whole file.
    if [[ -f /etc/fstab ]]; then
        awk -v s="$SUBMISSION_ROOT" '
            $0 !~ /^[[:space:]]*#/ && NF >= 3 && index($1, s "/") == 1 { print }
        ' /etc/fstab > "${target}/system/asms-fstab.entries"

        chmod 0600 "${target}/system/asms-fstab.entries"
    fi

    if [[ -d /etc/sudoers.d ]]; then
        while IFS= read -r -d '' file; do
            cp -a "$file" "${target}/system/"
        done < <(find /etc/sudoers.d -maxdepth 1 -type f -name '*asms*' -print0)
    fi
}

copy_credentials() {
    local target="${STAGING}/credentials"

    install -d -o root -g root -m 0700 "$target"

    [[ -d "$CREDENTIAL_DIR" ]] || return 0

    cp -a "${CREDENTIAL_DIR}/." "$target/" 2>/dev/null || true

    find "$target" -type f -exec chmod 0600 {} + 2>/dev/null || true
}

copy_submissions() {
    local target="${STAGING}/submissions"

    install -d -o root -g root -m 0700 "$target"

    if [[ ! -d "$SUBMISSION_ROOT" ]]; then
        warn "Submission root does not exist: $SUBMISSION_ROOT"
        return 0
    fi

    # Preserves ownership, modes and ACLs so a restore reproduces the access
    # model rather than a flattened copy of it.
    cp -a "${SUBMISSION_ROOT}/." "$target/"
}

copy_logs() {
    local target="${STAGING}/logs"

    install -d -o root -g root -m 0700 "$target"

    [[ -d "${ASMS_ROOT}/logs" ]] || return 0

    cp -a "${ASMS_ROOT}/logs/." "$target/" 2>/dev/null || true

    find "$target" -type f -exec chmod 0600 {} + 2>/dev/null || true
}

write_backup_info() {
    local type="$1"

    cat > "${STAGING}/backup-info.txt" <<EOF
Assignment Server Management System Backup

Backup type     : ${type}
Created         : $(timestamp)
Hostname        : ${HOST}
ASMS version    : $(grep -E '^Version=' "${ASMS_ROOT}/VERSION" 2>/dev/null | cut -d= -f2 || echo unknown)
ASMS root       : ${ASMS_ROOT}
Submission root : ${SUBMISSION_ROOT}

Students (${STUDENT_GROUP}): $(count_users_in_group "$STUDENT_GROUP")
$(get_student_users | sed 's/^/  /')

Faculty (${FACULTY_GROUP}): $(count_users_in_group "$FACULTY_GROUP")
$(get_faculty_users | sed 's/^/  /')

Disk usage:
$(df -h "$SUBMISSION_ROOT" 2>/dev/null || df -h /)

This backup contains ASMS configuration and data only. It deliberately does
NOT contain /etc/passwd, /etc/shadow, or any other system account database.
Restoring it will not recreate Linux accounts -- re-run provisioning for that.
EOF

    chmod 0600 "${STAGING}/backup-info.txt"
}

# The manifest is written to a temporary file outside the staging tree and
# moved in, so it cannot contain an entry for itself. A self-referential
# manifest can never verify.
write_manifest() {
    local manifest_tmp
    manifest_tmp="$(mktemp)"

    (
        cd "$STAGING"
        find . -type f -print0 |
            sort -z |
            xargs -0 --no-run-if-empty sha256sum
    ) > "$manifest_tmp"

    mv "$manifest_tmp" "${STAGING}/MANIFEST.sha256"
    chmod 0600 "${STAGING}/MANIFEST.sha256"
}

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

create_backup() {
    local type="$1"
    local prefix="$2"

    ensure_backup_root

    local name="${prefix}-${TIMESTAMP}_${HOST}"
    local archive="${BACKUP_ROOT}/${name}.tar.gz"

    [[ -e "$archive" ]] && die "Backup already exists: $archive"

    # Staged under a name matching the archive, so the tarball has exactly
    # one predictable top-level directory for restore to find.
    local work
    work="$(mktemp -d "${BACKUP_ROOT}/.staging-XXXXXX")"
    STAGING="${work}/${name}"

    install -d -o root -g root -m 0700 "$STAGING"

    info "Collecting ${type} backup..."

    write_backup_info "$type"

    case "$type" in
        Full)
            copy_configuration
            copy_credentials
            copy_submissions
            copy_logs
            ;;
        Configuration) copy_configuration ;;
        Submissions)   copy_submissions ;;
        Credentials)   copy_credentials ;;
        *) die "Unknown backup type: $type" ;;
    esac

    write_manifest

    info "Compressing..."

    # Built alongside the target then renamed, so an interrupted run never
    # leaves a truncated archive looking like a usable backup.
    tar -C "$work" -czf "${archive}.partial" "$name" ||
        die "Failed to create archive."

    mv "${archive}.partial" "$archive"
    chmod 0600 "$archive"

    # Archive-level integrity, separate from the manifest inside it.
    ( cd "$BACKUP_ROOT" && sha256sum "$(basename "$archive")" ) \
        > "${archive}.sha256"
    chmod 0600 "${archive}.sha256"

    sign_backup "$archive"

    rm -rf --one-file-system -- "$work"
    STAGING=""
    FINAL_ARCHIVE="$archive"

    log_action "BACKUP" "$(basename "$archive")" "SUCCESS"

    echo
    success "Backup created"
    printf '  %-12s %s\n' "Archive"  "$archive"
    printf '  %-12s %s\n' "Size"     "$(du -h "$archive" | cut -f1)"
    printf '  %-12s %s\n' "Checksum" "${archive}.sha256"
    [[ -f "${archive}.sha256.asc" ]] && printf '  %-12s %s\n' "Signature" "${archive}.sha256.asc"
    echo
    info "Verify at any time with:"
    printf '    cd %s && sha256sum -c %s\n' "$BACKUP_ROOT" "$(basename "${archive}.sha256")"
    echo
}

# A checksum sidecar proves the archive matches itself, generated by the
# same process that wrote both -- it catches accidental corruption, not a
# substituted archive with a regenerated checksum to match. Signing closes
# that gap for anyone who holds the private key, which whoever can merely
# write to BACKUP_ROOT does not. See data/config.conf for why this matters
# most once backups leave this host.
sign_backup() {
    local archive="$1"
    local sidecar="${archive}.sha256"

    if [[ -z "$BACKUP_GPG_KEY_ID" ]]; then
        warn "Backup is not GPG-signed (BACKUP_GPG_KEY_ID is not set in config.conf)."
        warn "Its checksum proves nothing was corrupted; it does not prove nothing was substituted."
        warn "Set BACKUP_GPG_KEY_ID before copying backups off this host."
        return 0
    fi

    if ! cmd_exists gpg; then
        warn "BACKUP_GPG_KEY_ID is set but gpg is not installed; backup was NOT signed."
        return 0
    fi

    if gpg --batch --yes --local-user "$BACKUP_GPG_KEY_ID" \
        --detach-sign --output "${sidecar}.asc" "$sidecar" 2>/dev/null; then
        chmod 0600 "${sidecar}.asc"
        success "Backup signed with key ${BACKUP_GPG_KEY_ID}"
    else
        warn "Signing failed with key ${BACKUP_GPG_KEY_ID}; backup was NOT signed."
    fi
}

list_backups() {
    header "Available Backups"

    [[ -d "$BACKUP_ROOT" ]] || {
        warn "No backup directory: $BACKUP_ROOT"
        return 0
    }

    local found=0 archive

    while IFS= read -r -d '' archive; do
        found=1
        printf '  %-52s %8s  %s\n' \
            "$(basename "$archive")" \
            "$(du -h "$archive" | cut -f1)" \
            "$(date -r "$archive" '+%Y-%m-%d %H:%M')"
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.tar.gz' -print0 | sort -z)

    ((found)) || warn "No backups found."
    echo
}

# ---------------------------------------------------------------------------

backup_menu() {
    header "Backup Assignment Server"

    echo "1. Full backup (configuration, credentials, submissions, logs)"
    echo "2. Configuration only"
    echo "3. Student submissions only"
    echo "4. Credentials only"
    echo "5. List existing backups"
    echo "6. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    case "$choice" in
        1) confirm "Create a FULL backup?"          && create_backup "Full"          "full" ;;
        2) confirm "Create a configuration backup?" && create_backup "Configuration" "configuration" ;;
        3) confirm "Back up all student submissions?" && create_backup "Submissions" "submissions" ;;
        4) confirm "Back up credential files?"      && create_backup "Credentials"   "credentials" ;;
        5) list_backups ;;
        6) return 0 ;;
        *) die "Invalid choice." ;;
    esac
}

usage() {
    cat <<EOF
Usage: backup_system.sh [option]

  --full           Configuration, credentials, submissions and logs
  --config         Configuration only
  --submissions    Student submissions only
  --credentials    Credential files only
  --list           List existing backups
  -h, --help       Show this help

With no option an interactive menu is shown.
EOF
}

main() {
    require_command tar
    require_command sha256sum

    case "${1:-}" in
        --full)        create_backup "Full"          "full" ;;
        --config)      create_backup "Configuration" "configuration" ;;
        --submissions) create_backup "Submissions"   "submissions" ;;
        --credentials) create_backup "Credentials"   "credentials" ;;
        --list)        list_backups ;;
        -h|--help)     usage ;;
        "")            backup_menu ;;
        *)             usage >&2; die "Unknown option: $1" ;;
    esac
}

main "$@"
