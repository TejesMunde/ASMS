#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: restore_backup.sh
# Version: 2.0.0
#
# Restores backups produced by backup_system.sh.
#
# Safety rules, in order of importance:
#
#   1. Only ASMS-owned paths are written. Never /etc/passwd, /etc/shadow, or
#      any other path that happens to be inside the archive. A backup is not
#      a trusted filesystem image.
#   2. /etc/fstab is edited surgically: ASMS bind lines are replaced, every
#      other line is left exactly as it was.
#   3. A safety backup of current data is taken before anything is written.
#   4. The archive's integrity is verified before it is trusted.
#   5. Submissions are merged, never deleted, so restoring an old backup
#      cannot destroy work submitted since it was taken.
#
# The scaffold looked for components at the extraction root, but the archive
# puts everything under one top-level directory. Restore found nothing,
# reported success, and changed nothing. That directory is now detected.
#
# Usage:
#   restore_backup.sh                              interactive menu
#   restore_backup.sh --list
#   restore_backup.sh --verify ARCHIVE
#   restore_backup.sh --restore ARCHIVE --components configuration,credentials
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

WORK_DIR=""
CONTENT_DIR=""
SAFETY_BACKUP=""

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf --one-file-system -- "$WORK_DIR"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

list_backups() {
    [[ -d "$BACKUP_ROOT" ]] || {
        warn "No backup directory: $BACKUP_ROOT"
        return 1
    }

    local found=0 archive

    echo "Available backups:"
    echo

    while IFS= read -r -d '' archive; do
        found=1
        printf '  %-52s %8s  %s\n' \
            "$(basename "$archive")" \
            "$(du -h "$archive" | cut -f1)" \
            "$(date -r "$archive" '+%Y-%m-%d %H:%M')"
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.tar.gz' -print0 | sort -z)

    echo

    ((found)) || { warn "No backups found."; return 1; }
}

resolve_backup() {
    local name="$1"

    # Selected by basename only. A path would let a caller point the restore
    # at an archive from anywhere on the filesystem.
    [[ "$name" != */* && "$name" != .* ]] ||
        { error "Invalid backup name: $name"; return 1; }

    local path="${BACKUP_ROOT}/${name}"

    [[ -f "$path" && "$path" == *.tar.gz ]] ||
        { error "Backup not found: $name"; return 1; }

    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------------

verify_archive_checksum() {
    local archive="$1"
    local sidecar="${archive}.sha256"

    [[ -f "$sidecar" ]] || {
        warn "No .sha256 sidecar for this archive; skipping archive-level check."
        return 0
    }

    info "Verifying archive checksum..."

    ( cd "$BACKUP_ROOT" && sha256sum -c "$(basename "$sidecar")" >/dev/null ) || {
        error "Archive checksum does not match. The file is corrupt or was altered."
        return 1
    }

    success "Archive checksum verified."

    verify_archive_signature "$sidecar" "${sidecar}.asc"
}

# A checksum alone proves the archive matches its own sidecar; it does not
# prove neither was substituted by whoever can write to BACKUP_ROOT, or
# whoever handled a copy made for off-site storage. A signature is the
# difference between those two claims -- see data/config.conf.
verify_archive_signature() {
    local sidecar="$1" signature="$2"

    if [[ -f "$signature" ]]; then
        if ! cmd_exists gpg; then
            warn "Backup has a signature (${signature##*/}) but gpg is not installed; cannot verify it."
            confirm "Continue without verifying the signature?" || return 1
            return 0
        fi

        if gpg --batch --verify "$signature" "$sidecar" 2>/dev/null; then
            success "Backup signature verified."
        else
            error "Backup signature does NOT verify. Treat this archive as untrusted."
            confirm "Continue anyway? (strongly discouraged)" || return 1
        fi
        return 0
    fi

    if [[ -n "$BACKUP_GPG_KEY_ID" ]]; then
        warn "BACKUP_GPG_KEY_ID is configured but this archive has no signature."
        warn "Its provenance cannot be verified -- it may predate signing, or the signature may be missing for another reason."
        confirm "Continue with an unsigned archive?" || return 1
    fi

    return 0
}

extract_backup() {
    local archive="$1"

    WORK_DIR="$(mktemp -d "${BACKUP_ROOT}/.restore-XXXXXX")"

    tar -tzf "$archive" >/dev/null 2>&1 ||
        { error "Not a readable gzip archive: $archive"; return 1; }

    # Refuse absolute paths and traversal before extracting anything.
    if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        error "Archive contains unsafe paths; refusing to extract."
        return 1
    fi

    # Refuse symlink members too. A legitimate backup never contains one --
    # backup_system.sh builds archives with cp -a from root-owned ASMS paths,
    # none of which are symlinks -- so a symlink entry only means the
    # archive was hand-crafted or tampered with. Left unchecked, a symlink
    # placed early in the archive (e.g. "configuration -> /etc") could steer
    # later members in the same archive to extract through it and write
    # outside WORK_DIR.
    if tar -tvzf "$archive" 2>/dev/null | grep -Eq '^l'; then
        error "Archive contains a symbolic link entry; refusing to extract."
        return 1
    fi

    info "Extracting..."
    tar -xzf "$archive" -C "$WORK_DIR"

    # The archive holds exactly one top-level directory. Find it rather than
    # assuming the components sit at the extraction root.
    local entries=()

    while IFS= read -r -d '' entry; do
        entries+=("$entry")
    done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -print0)

    if ((${#entries[@]} == 1)) && [[ -d "${entries[0]}" ]]; then
        CONTENT_DIR="${entries[0]}"
    else
        # An older or hand-made archive with components at the root.
        CONTENT_DIR="$WORK_DIR"
    fi

    [[ -d "$CONTENT_DIR" ]] || { error "Could not locate backup content."; return 1; }
}

verify_manifest() {
    local manifest="${CONTENT_DIR}/MANIFEST.sha256"

    [[ -f "$manifest" ]] || {
        warn "No manifest in this backup; contents cannot be verified."
        confirm "Continue without content verification?" || return 1
        return 0
    }

    info "Verifying backup contents..."

    ( cd "$CONTENT_DIR" && sha256sum -c --quiet MANIFEST.sha256 ) || {
        error "Backup contents failed verification. Files differ from the manifest."
        return 1
    }

    success "Backup contents verified."
}

show_backup_info() {
    local info_file="${CONTENT_DIR}/backup-info.txt"

    [[ -f "$info_file" ]] || return 0

    header "Backup Contents"
    sed -n '1,12p' "$info_file" | sed 's/^/  /'
    echo

    local component
    echo "  Components present:"
    for component in configuration credentials submissions logs; do
        [[ -d "${CONTENT_DIR}/${component}" ]] &&
            printf '    - %s\n' "$component"
    done
    echo
}

# ---------------------------------------------------------------------------
# Safety backup
# ---------------------------------------------------------------------------

safety_backup() {
    local module="${ASMS_MODULE_DIR}/backup_system.sh"

    if [[ -x "$module" ]]; then
        info "Creating a safety backup of current data..."

        if ASMS_ASSUME_YES=1 "$module" --full >/dev/null 2>&1; then
            SAFETY_BACKUP="$(find "$BACKUP_ROOT" -maxdepth 1 -name 'full-*.tar.gz' \
                -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
            success "Safety backup: $(basename "${SAFETY_BACKUP:-unknown}")"
            return 0
        fi

        warn "Safety backup failed."
    else
        warn "backup_system.sh is not executable; cannot create a safety backup."
    fi

    confirm "Continue WITHOUT a safety backup?" || return 1
}

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

restore_configuration() {
    local source="${CONTENT_DIR}/configuration"

    [[ -d "$source" ]] || { warn "No configuration in this backup."; return 0; }

    local file
    for file in VERSION README.md CHANGELOG.md; do
        [[ -f "${source}/${file}" ]] &&
            install -o root -g root -m 0644 "${source}/${file}" "${ASMS_ROOT}/${file}"
    done

    install -d -o root -g root -m 0750 "${ASMS_ROOT}/data"

    for file in config.conf students.csv faculty.csv; do
        [[ -f "${source}/${file}" ]] &&
            install -o root -g root -m 0640 "${source}/${file}" "${ASMS_ROOT}/data/${file}"
    done

    if [[ -d "${source}/assignment-server/modules" ]]; then
        install -d -o root -g root -m 0750 "${ASMS_ROOT}/modules"

        while IFS= read -r -d '' module; do
            install -o root -g root -m 0750 "$module" \
                "${ASMS_ROOT}/modules/$(basename "$module")"
        done < <(find "${source}/assignment-server/modules" -maxdepth 1 -type f -print0)
    fi

    [[ -f "${source}/assignment-server/assignment-admin" ]] &&
        install -o root -g root -m 0750 \
            "${source}/assignment-server/assignment-admin" \
            "${ASMS_ROOT}/assignment-admin"

    if [[ -d "${source}/assignment-server/templates" ]]; then
        install -d -o root -g root -m 0755 "${ASMS_ROOT}/templates"
        cp -a "${source}/assignment-server/templates/." "${ASMS_ROOT}/templates/"
    fi

    # Only the ASMS audit rules file, by its configured name.
    local audit_backup="${source}/system/$(basename "$AUDIT_RULE_FILE")"

    if [[ -f "$audit_backup" ]]; then
        install -d -o root -g root -m 0750 "$(dirname "$AUDIT_RULE_FILE")"
        install -o root -g root -m 0640 "$audit_backup" "$AUDIT_RULE_FILE"
    fi

    restore_fstab_entries "${source}/system/asms-fstab.entries"

    success "Configuration restored."
}

# ASMS bind lines are replaced; every other line in /etc/fstab is preserved
# byte for byte. The file is never overwritten wholesale -- a bad fstab
# leaves the machine unbootable.
restore_fstab_entries() {
    local entries="$1"

    [[ -f "$entries" ]] || return 0

    local tmp
    tmp="$(mktemp)"

    awk -v s="$SUBMISSION_ROOT" '
        $0 ~ /^[[:space:]]*#/ { print; next }
        NF >= 3 && index($1, s "/") == 1 { next }
        { print }
    ' /etc/fstab > "$tmp"

    cat "$entries" >> "$tmp"

    # Written in place to preserve the original ownership and mode.
    cat "$tmp" > /etc/fstab
    rm -f "$tmp"

    info "ASMS entries in /etc/fstab updated."
}

restore_credentials() {
    local source="${CONTENT_DIR}/credentials"

    [[ -d "$source" ]] || { warn "No credentials in this backup."; return 0; }

    install -d -o root -g root -m "$CREDENTIAL_DIR_MODE" "$CREDENTIAL_DIR"

    # Only the two known credential files, never everything in the directory.
    local file
    for file in student_credentials.csv faculty_credentials.csv; do
        [[ -f "${source}/${file}" ]] &&
            install -o root -g root -m "$CREDENTIAL_FILE_MODE" \
                "${source}/${file}" "${CREDENTIAL_DIR}/${file}"
    done

    success "Credentials restored."
}

# Merged, not replaced. Deleting the current archive first would mean a
# restore of last week's backup destroys everything submitted since.
restore_submissions() {
    local source="${CONTENT_DIR}/submissions"

    [[ -d "$source" ]] || { warn "No submissions in this backup."; return 0; }

    install -d -o root -g root -m "$SUBMISSION_ROOT_MODE" "$SUBMISSION_ROOT"

    cp -a "${source}/." "${SUBMISSION_ROOT}/"

    success "Submissions restored (merged with existing)."
    info "Existing submissions were not deleted."
}

restore_logs() {
    local source="${CONTENT_DIR}/logs"

    [[ -d "$source" ]] || { warn "No logs in this backup."; return 0; }

    install -d -o root -g root -m 0700 "${ASMS_ROOT}/logs"
    cp -a "${source}/." "${ASMS_ROOT}/logs/"

    find "${ASMS_ROOT}/logs" -type f -exec chmod 0600 {} + 2>/dev/null || true

    success "Logs restored."
}

restore_component() {
    case "$1" in
        configuration) restore_configuration ;;
        credentials)   restore_credentials ;;
        submissions)   restore_submissions ;;
        logs)          restore_logs ;;
        *) error "Unknown component: $1"; return 1 ;;
    esac
}

reload_services() {
    cmd_exists augenrules &&
        { augenrules --load >/dev/null 2>&1 || warn "Audit rules could not be reloaded."; }

    cmd_exists systemctl &&
        { systemctl daemon-reload >/dev/null 2>&1 || true; }

    # fstab changed, so the live mounts may no longer match it.
    if [[ -x "${ASMS_MODULE_DIR}/configure_mounts.sh" ]]; then
        info "Re-checking student mounts..."
        "${ASMS_MODULE_DIR}/configure_mounts.sh" --repair-all >/dev/null 2>&1 ||
            warn "Some student mounts need attention. Run Verify Server."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

perform_restore() {
    local archive="$1"
    shift
    local components=("$@")

    info "Selected backup: $(basename "$archive")"

    verify_archive_checksum "$archive" || return 1
    extract_backup "$archive" || return 1
    verify_manifest || return 1
    show_backup_info

    echo "  Will restore: ${components[*]}"
    echo

    confirm "Proceed with restore?" || { info "Cancelled."; return 0; }

    safety_backup || { info "Restore cancelled."; return 1; }

    local component
    for component in "${components[@]}"; do
        restore_component "$component" || true
    done

    reload_services

    log_action "RESTORE" "$(basename "$archive")" "SUCCESS"

    echo
    success "Restore completed."
    printf '  Safety backup: %s\n' "$(basename "${SAFETY_BACKUP:-none}")"
    echo
    warn "Run Verify Server now to confirm the system is consistent."
    warn "Restoring does not recreate Linux accounts; re-run provisioning if needed."
}

restore_menu() {
    header "Restore Assignment Server Backup"

    list_backups || return 0

    local name
    name="$(prompt_value "Backup name")"
    [[ -n "$name" ]] || { error "No backup selected."; return 1; }

    local archive
    archive="$(resolve_backup "$name")" || return 1

    echo
    echo "What should be restored?"
    echo
    echo "1. Configuration"
    echo "2. Credentials"
    echo "3. Student submissions"
    echo "4. Logs"
    echo "5. Everything available"
    echo "6. Cancel"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    local components=()

    case "$choice" in
        1) components=(configuration) ;;
        2) components=(credentials) ;;
        3) components=(submissions) ;;
        4) components=(logs) ;;
        5) components=(configuration credentials submissions logs) ;;
        6) info "Cancelled."; return 0 ;;
        *) die "Invalid choice." ;;
    esac

    perform_restore "$archive" "${components[@]}"
}

usage() {
    cat <<EOF
Usage: restore_backup.sh [option]

  --list                      List available backups
  --verify ARCHIVE            Check an archive's integrity, restore nothing
  --restore ARCHIVE           Restore from ARCHIVE (basename, not a path)
  --components a,b,c          Which components: configuration, credentials,
                              submissions, logs (default: all present)
  -h, --help                  Show this help

With no option an interactive menu is shown.
EOF
}

verify_only() {
    local archive
    archive="$(resolve_backup "$1")" || return 1

    header "Verify Backup"

    verify_archive_checksum "$archive" || return 1
    extract_backup "$archive" || return 1
    verify_manifest || return 1
    show_backup_info

    success "Backup is intact and restorable."
}

main() {
    require_command tar
    require_command sha256sum

    local archive_name="" component_list="" action=""

    while (($# > 0)); do
        case "$1" in
            --list)       action="list"; shift ;;
            --verify)     [[ -n "${2:-}" ]] || die "--verify requires an archive name."
                          action="verify"; archive_name="$2"; shift 2 ;;
            --restore)    [[ -n "${2:-}" ]] || die "--restore requires an archive name."
                          action="restore"; archive_name="$2"; shift 2 ;;
            --components) [[ -n "${2:-}" ]] || die "--components requires a list."
                          component_list="$2"; shift 2 ;;
            -h|--help)    usage; return 0 ;;
            *)            usage >&2; die "Unknown option: $1" ;;
        esac
    done

    case "$action" in
        list)   list_backups ;;
        verify) verify_only "$archive_name" ;;
        restore)
            local archive
            archive="$(resolve_backup "$archive_name")" || return 1

            local components=()

            if [[ -n "$component_list" ]]; then
                IFS=',' read -ra components <<< "$component_list"
            else
                components=(configuration credentials submissions logs)
            fi

            perform_restore "$archive" "${components[@]}"
            ;;
        *) restore_menu ;;
    esac
}

main "$@"
