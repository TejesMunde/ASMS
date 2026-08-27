#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: configure_mounts.sh
# Version: 2.0.0
#
# THE authority on the student submission archive and its read-only view.
# Archive creation, ACLs, bind mounts, fstab entries, verification and
# unmounting all live here and nowhere else. Other modules source this file
# and call its functions; none of them reimplement any part of it.
#
# Architecture:
#
#   /srv/submissions/<student>        authoritative archive
#       root:root 0750 + ACL u:<student>:rX, g:<faculty>:rX
#       Never writable by a student. Only the setuid submit helper writes here.
#
#   /home/<student>/submissions       read-only bind-mounted view
#       The student's window onto their own archive. Read-only at the mount
#       level, so the kernel refuses writes regardless of file permissions.
#
# A student must never receive a mount of another student's archive.
#
# Usage as a library:
#   source "${MODULE_DIR}/configure_mounts.sh"
#   configure_persistent_mount alice
#
# Usage as a command:
#   configure_mounts.sh --configure alice
#   configure_mounts.sh --configure-all
#   configure_mounts.sh --verify-all
#   configure_mounts.sh --repair-all       (run at boot by asms-mounts.service)
#   configure_mounts.sh --remove alice
#   configure_mounts.sh                    (interactive menu)
#

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

ensure_config

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

ensure_submission_root() {
    # 0711: traversable but not listable. A student can reach their own
    # archive by exact name; nobody can enumerate the directory to discover
    # which other students exist.
    install -d -o root -g root -m "$SUBMISSION_ROOT_MODE" "$SUBMISSION_ROOT"
}

# The ACLs are the entire access-control story for the archive:
#
#   owner root      the only writer, via the setuid submit helper
#   group root      deliberately NOT the students group; membership grants nothing
#   u:<student>:rX  read and traverse, for exactly one named student
#   g:<faculty>:rX  read and traverse for faculty
#
# rX rather than rx: capital X grants execute on directories only, so a
# submitted file never becomes executable through the ACL.
#
# The default (-d) entries make future submission directories inherit the
# same access, so the submit helper does not have to re-apply them.
apply_archive_acls() {
    local username="$1"
    local archive
    archive="$(student_archive_path "$username")"

    cmd_exists setfacl || {
        error "setfacl not found; cannot configure archive access for $username."
        error "Install the 'acl' package (Install Development Environment)."
        return 1
    }

    setfacl -m "u:${username}:rX" "$archive" || return 1
    setfacl -m "g:${FACULTY_GROUP}:rX" "$archive" || return 1

    setfacl -d -m "u:${username}:rX" "$archive" || return 1
    setfacl -d -m "g:${FACULTY_GROUP}:rX" "$archive" || return 1

    return 0
}

# Creates the archive if absent and (re-)applies its access control.
#
# The mode is set at creation time by install(1) and never with a later
# chmod. chmod on an ACL-bearing directory rewrites the ACL mask, which
# silently strips every named entry -- the scaffold did exactly this and
# revoked both student and faculty read access without an error message.
ensure_student_archive() {
    local username="$1"
    local archive
    archive="$(student_archive_path "$username")"

    ensure_submission_root

    if [[ ! -d "$archive" ]]; then
        install -d -o root -g root -m "$STUDENT_ARCHIVE_MODE" "$archive"
        log_action "CREATE_ARCHIVE" "$username" "SUCCESS"
    fi

    apply_archive_acls "$username"
}

# ---------------------------------------------------------------------------
# Mount point
# ---------------------------------------------------------------------------

# Owned by root and not writable by the student, so that if the mount is ever
# absent the student sees an empty directory they cannot write into rather
# than a writable one they might mistake for their submissions.
ensure_mount_point() {
    local username="$1"
    local mount_dir
    mount_dir="$(student_mount_path "$username")"

    mountpoint -q "$mount_dir" 2>/dev/null && return 0

    install -d -o root -g root -m 0555 "$mount_dir"
}

# ---------------------------------------------------------------------------
# Mount state
# ---------------------------------------------------------------------------

# Is the target bound to this student's own archive?
#
# Compared by device and inode rather than by parsing findmnt's SOURCE.
# For a bind mount findmnt reports the underlying device with the subpath in
# brackets -- "/dev/sda2[/srv/submissions/alice]", not "/srv/submissions/alice"
# -- so a direct string comparison against the archive path never matches.
# The scaffold compared it that way and therefore treated every correct mount
# as an unexpected one.
#
# A bind mount makes target and source the same inode on the same device,
# which is exact and immune to how findmnt formats its output.
mount_points_at_archive() {
    local username="$1"
    local target archive

    target="$(student_mount_path "$username")"
    archive="$(student_archive_path "$username")"

    [[ -d "$target" && -d "$archive" ]] || return 1

    local target_id archive_id
    target_id="$(stat -c '%d:%i' "$target" 2>/dev/null)" || return 1
    archive_id="$(stat -c '%d:%i' "$archive" 2>/dev/null)" || return 1

    [[ "$target_id" == "$archive_id" ]]
}

mount_is_readonly() {
    local target="$1"
    local options

    options="$(findmnt -n -o OPTIONS --first-only "$target" 2>/dev/null)" || return 1

    [[ ",${options}," == *",ro,"* ]]
}

# The full correctness test: it is a mount, it points at this student's own
# archive, and it is read-only.
mount_is_correct() {
    local username="$1"
    local target
    target="$(student_mount_path "$username")"

    mountpoint -q "$target" 2>/dev/null || return 1
    mount_points_at_archive "$username" || return 1
    mount_is_readonly "$target"
}

# ---------------------------------------------------------------------------
# Mount / unmount
# ---------------------------------------------------------------------------

# A bind mount cannot be made read-only in a single operation: the kernel
# ignores everything but "bind" on the initial call and applies the rest only
# on a subsequent remount. Both steps are always performed here, which is
# also why this works identically on util-linux older than 2.37.
mount_student() {
    local username="$1"
    local archive target

    is_student_user "$username" || {
        error "Not a student account: $username"
        log_action "MOUNT_STUDENT" "$username" "REFUSED_NOT_STUDENT"
        return 1
    }

    archive="$(student_archive_path "$username")"
    target="$(student_mount_path "$username")"

    ensure_student_archive "$username" || return 1
    ensure_mount_point "$username"

    if mountpoint -q "$target" 2>/dev/null; then
        if ! mount_points_at_archive "$username"; then
            error "$target is mounted from something other than ${archive}."
            error "Refusing to modify it automatically."
            log_action "MOUNT_STUDENT" "$username" "FAILED_UNEXPECTED_SOURCE"
            return 1
        fi

        # Correct source. Re-assert read-only in case it was remounted
        # read-write, or the kernel ignored `ro` at boot.
        if ! mount_is_readonly "$target"; then
            warn "$username: mount was not read-only; remounting."
            mount -o "remount,${STUDENT_MOUNT_OPTIONS}" "$target" || {
                error "$username: failed to remount read-only."
                log_action "MOUNT_STUDENT" "$username" "FAILED_REMOUNT_RO"
                return 1
            }
        fi

        log_action "MOUNT_STUDENT" "$username" "ALREADY_CONFIGURED"
        return 0
    fi

    mount --bind "$archive" "$target" || {
        error "$username: bind mount failed."
        log_action "MOUNT_STUDENT" "$username" "FAILED_BIND"
        return 1
    }

    mount -o "remount,${STUDENT_MOUNT_OPTIONS}" "$target" || {
        umount "$target" >/dev/null 2>&1 || true
        error "$username: read-only remount failed; mount removed."
        log_action "MOUNT_STUDENT" "$username" "FAILED_REMOUNT"
        return 1
    }

    # Never leave a writable view behind. If it cannot be made read-only the
    # mount is removed rather than left as a hole in the security model.
    if ! mount_is_correct "$username"; then
        umount "$target" >/dev/null 2>&1 || true
        error "$username: mount failed verification; mount removed."
        log_action "MOUNT_STUDENT" "$username" "FAILED_VERIFY"
        return 1
    fi

    log_action "MOUNT_STUDENT" "$username" "SUCCESS"
    success "$username: read-only submission view mounted."
}

unmount_student() {
    local username="$1"
    local target
    target="$(student_mount_path "$username")"

    mountpoint -q "$target" 2>/dev/null || return 0

    if ! mount_points_at_archive "$username"; then
        error "$target is mounted from an unexpected source; refusing to unmount."
        log_action "UNMOUNT_STUDENT" "$username" "REFUSED_UNEXPECTED_SOURCE"
        return 1
    fi

    if umount "$target" 2>/dev/null; then
        log_action "UNMOUNT_STUDENT" "$username" "SUCCESS"
        return 0
    fi

    # A logged-in student holding the directory open blocks a normal unmount.
    # A lazy unmount detaches it now and cleans up when the last reference
    # closes, which is preferable to leaving a stale mount that would block
    # account removal.
    warn "$username: normal unmount failed; using lazy unmount."

    if umount -l "$target" 2>/dev/null; then
        log_action "UNMOUNT_STUDENT" "$username" "SUCCESS_LAZY"
        return 0
    fi

    error "$username: unable to unmount $target"
    log_action "UNMOUNT_STUDENT" "$username" "FAILED"
    return 1
}

# ---------------------------------------------------------------------------
# /etc/fstab
# ---------------------------------------------------------------------------
#
# Entries are matched on the exact source/target pair so that adding is
# idempotent and removal never touches an unrelated line.

FSTAB="${FSTAB:-/etc/fstab}"

fstab_entry_exists() {
    local source="$1" target="$2"

    [[ -f "$FSTAB" ]] || return 1

    awk -v s="$source" -v t="$target" '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 && $1 == s && $2 == t { found = 1 }
        END { exit !found }
    ' "$FSTAB"
}

add_fstab_entry() {
    local username="$1"
    local source target
    source="$(student_archive_path "$username")"
    target="$(student_mount_path "$username")"

    fstab_entry_exists "$source" "$target" && return 0

    printf '%s %s none %s 0 0\n' \
        "$source" "$target" "$STUDENT_MOUNT_OPTIONS" >> "$FSTAB"

    log_action "ADD_FSTAB_MOUNT" "$username" "SUCCESS"
}

remove_fstab_entry() {
    local username="$1"
    local source target tmp
    source="$(student_archive_path "$username")"
    target="$(student_mount_path "$username")"

    [[ -f "$FSTAB" ]] || return 0
    fstab_entry_exists "$source" "$target" || return 0

    tmp="$(mktemp)"

    awk -v s="$source" -v t="$target" '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 && $1 == s && $2 == t { next }
        { print }
    ' "$FSTAB" > "$tmp"

    # Written in place rather than moved, to preserve the original file's
    # ownership and mode.
    cat "$tmp" > "$FSTAB"
    rm -f "$tmp"

    log_action "REMOVE_FSTAB_MOUNT" "$username" "SUCCESS"
}

# ---------------------------------------------------------------------------
# Composite operations
# ---------------------------------------------------------------------------

# The entry point provisioning uses: archive, ACLs, fstab entry, live mount.
configure_persistent_mount() {
    local username="$1"

    is_student_user "$username" || {
        error "Not a student account: $username"
        return 1
    }

    ensure_student_archive "$username" || return 1
    add_fstab_entry "$username"
    mount_student "$username" || return 1

    log_action "CONFIGURE_MOUNT" "$username" "SUCCESS"
}

# The entry point removal uses: live mount and fstab entry gone. The archive
# is deliberately left alone -- deciding its fate belongs to the caller.
deconfigure_mount() {
    local username="$1"

    unmount_student "$username" || return 1
    remove_fstab_entry "$username"
}

for_each_student() {
    local action="$1"
    local username failed=0 count=0

    while IFS= read -r username; do
        [[ -n "$username" ]] || continue
        count=$((count + 1))
        "$action" "$username" || failed=$((failed + 1))
    done < <(get_student_users)

    echo
    printf 'Students processed: %d\n' "$count"
    printf 'Failures          : %d\n' "$failed"

    ((failed == 0))
}

configure_all_students() { for_each_student configure_persistent_mount; }

verify_student_mount() {
    local username="$1"
    local target
    target="$(student_mount_path "$username")"

    if ! mountpoint -q "$target" 2>/dev/null; then
        error "$username: submission view is not mounted."
        return 1
    fi

    if ! mount_points_at_archive "$username"; then
        error "$username: mounted from something other than their own archive."
        return 1
    fi

    if ! mount_is_readonly "$target"; then
        error "$username: submission view is NOT read-only."
        return 1
    fi

    success "$username: read-only view of own archive."
}

verify_all_mounts() { for_each_student verify_student_mount; }

# Bring every student mount back to the correct state. Run at boot by
# asms-mounts.service, which covers the case of util-linux older than 2.37
# ignoring `ro` on a bind entry in fstab and mounting it read-write.
repair_all_mounts() {
    local username failed=0 repaired=0 count=0

    while IFS= read -r username; do
        [[ -n "$username" ]] || continue
        count=$((count + 1))

        mount_is_correct "$username" && continue

        repaired=$((repaired + 1))

        if mount_student "$username"; then
            success "$username: mount repaired."
        else
            failed=$((failed + 1))
        fi
    done < <(get_student_users)

    printf 'Students checked: %d\n' "$count"
    printf 'Repaired        : %d\n' "$repaired"
    printf 'Failures        : %d\n' "$failed"

    log_action "REPAIR_MOUNTS" "all" \
        "checked=${count};repaired=${repaired};failed=${failed}"

    ((failed == 0))
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

configure_mounts_usage() {
    cat <<EOF
Usage: configure_mounts.sh [option]

  --configure USER     Archive, ACLs, fstab entry and mount for one student
  --configure-all      The same for every student
  --verify-all         Report on every student's mount (changes nothing)
  --repair-all         Restore any mount that is missing or not read-only
  --remove USER        Unmount and drop the fstab entry (archive is kept)
  --mount USER         Mount only
  --unmount USER       Unmount only
  -h, --help           Show this help

With no option an interactive menu is shown.
EOF
}

configure_mounts_menu() {
    header "Student Mount Configuration"

    echo "1. Configure mounts for all students"
    echo "2. Configure mounts for selected students"
    echo "3. Verify all student mounts"
    echo "4. Repair all student mounts"
    echo "5. Return"
    echo

    local choice
    choice="$(prompt_value "Choice")"

    case "$choice" in
        1)
            confirm "Configure persistent read-only mounts for ALL students?" ||
                { info "Cancelled."; return 0; }
            configure_all_students
            ;;
        2)
            local input username failed=0
            input="$(prompt_value "Student IDs (comma separated)")"

            [[ -n "$input" ]] || { error "No student IDs supplied."; return 1; }

            IFS=',' read -ra selected <<< "$input"

            for username in "${selected[@]}"; do
                username="${username//[[:space:]]/}"
                [[ -n "$username" ]] || continue
                configure_persistent_mount "$username" || failed=$((failed + 1))
            done

            ((failed == 0))
            ;;
        3) verify_all_mounts ;;
        4) repair_all_mounts ;;
        5) return 0 ;;
        *) error "Invalid choice."; return 1 ;;
    esac
}

configure_mounts_main() {
    require_root

    require_command mount
    require_command mountpoint
    require_command findmnt
    require_command stat

    case "${1:-}" in
        --configure)     [[ -n "${2:-}" ]] || die "--configure requires a username."
                         configure_persistent_mount "$2" ;;
        --configure-all) configure_all_students ;;
        --verify-all)    verify_all_mounts ;;
        --repair-all)    repair_all_mounts ;;
        --remove)        [[ -n "${2:-}" ]] || die "--remove requires a username."
                         deconfigure_mount "$2" ;;
        --mount)         [[ -n "${2:-}" ]] || die "--mount requires a username."
                         mount_student "$2" ;;
        --unmount)       [[ -n "${2:-}" ]] || die "--unmount requires a username."
                         unmount_student "$2" ;;
        -h|--help)       configure_mounts_usage ;;
        "")              configure_mounts_menu ;;
        *)               configure_mounts_usage >&2
                         die "Unknown option: $1" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    configure_mounts_main "$@"
fi
