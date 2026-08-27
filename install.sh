#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Installer
# Version: 2.0.0
#
# Installs this source tree into /opt/assignment-server and wires up the
# system-level pieces (groups, submission root, submit command).
#
# This script is deliberately self-contained: it cannot source utils.sh,
# because utils.sh is one of the things it installs.
#
# It is idempotent. Re-running it upgrades an existing installation without
# destroying configuration, credentials, logs, backups, or submissions.
#
# This script is not run directly. Installation goes through the single entry
# point, which sets ASMS_VIA_ADMIN=1 before calling it:
#
#   sudo ./assignment-admin            # menu -> Install / upgrade ASMS
#   sudo ./assignment-admin --install  # install straight away
#   sudo ./assignment-admin --check    # report what would change, install nothing
#

set -Eeuo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/opt/assignment-server"
CHECK_ONLY=0

BUILD_DIR=""

cleanup() {
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] && rm -rf -- "$BUILD_DIR"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

_red="\033[31m"; _green="\033[32m"; _yellow="\033[33m"; _blue="\033[34m"; _reset="\033[0m"

info()    { echo -e "${_blue}[INFO]${_reset} $*"; }
success() { echo -e "${_green}[ OK ]${_reset} $*"; }
warn()    { echo -e "${_yellow}[WARN]${_reset} $*"; }
error()   { echo -e "${_red}[FAIL]${_reset} $*" >&2; }

die() { error "$*"; exit 1; }

step() {
    echo
    echo "== $* =="
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --prefix PATH   Installation root (default: /opt/assignment-server)
  --check         Report what would change without modifying anything
  -h, --help      Show this help
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --prefix)
                [[ -n "${2:-}" ]] || die "--prefix requires a path."
                PREFIX="$2"
                shift 2
                ;;
            --check)
                CHECK_ONLY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Unknown argument: $1"
                ;;
        esac
    done

    [[ "$PREFIX" == /* ]] || die "--prefix must be an absolute path."
}

# ---------------------------------------------------------------------------
# What gets installed
# ---------------------------------------------------------------------------
#
# An explicit list, not a glob: a stray file in the source directory must
# never end up executable in the modules directory.

MODULES=(
    utils.sh
    logger.sh
    generate_password.sh
    configure_mounts.sh
    provision_students.sh
    provision_faculty.sh
    remove_students.sh
    remove_faculty.sh
    install_devtools.sh
    generate_audit.sh
    backup_system.sh
    restore_backup.sh
    reset_semester.sh
    verify_server.sh
)

# Directories created inside PREFIX, as "relative_path:mode".
#
# The root of PREFIX is 0700, not the more usual 0755: every legitimate
# reader of anything under here is root (assignment-admin is only ever run
# via sudo; the systemd unit and the setuid submit chain both run as root
# already), so there is no one who needs it to be traversable and nothing
# gained by leaving it world-readable. Before this, any local account could
# `ls /opt/assignment-server` and see credentials/, logs/, backups/ and
# every module by name, even though none of their contents were reachable.
PREFIX_DIRS=(
    ":0700"
    "modules:0750"
    "data:0750"
    "templates:0755"
    "credentials:0700"
    "logs:0700"
    "backups:0700"
    "archive:0700"
    "archive/semesters:0700"
)

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_root() {
    [[ $EUID -eq 0 ]] || die "install.sh must be run as root (use sudo)."
}

# Installation is only offered through the single entry point. assignment-admin
# sets ASMS_VIA_ADMIN=1 before calling this script; a direct invocation has it
# unset and is refused, so there is one documented way in.
require_admin_entry() {
    [[ "${ASMS_VIA_ADMIN:-}" == "1" ]] && return 0
    error "install.sh is not run directly."
    error "Install ASMS through the single entry point:"
    error "    sudo ./assignment-admin"
    exit 1
}

require_source_files() {
    local missing=0 file

    for file in "${MODULES[@]}" assignment-admin VERSION data/config.conf; do
        if [[ ! -f "${SRC_DIR}/${file}" ]]; then
            error "Missing source file: ${file}"
            missing=1
        fi
    done

    ((missing == 0)) || die "Source tree is incomplete; refusing to install."
}

require_commands() {
    local missing=0 command_name

    # Commands the installer itself needs. Runtime dependencies (setfacl,
    # auditctl, ...) are reported by verify_server.sh, not enforced here,
    # because install_devtools.sh is what installs them.
    for command_name in install groupadd getent; do
        command -v "$command_name" >/dev/null 2>&1 || {
            error "Required command not found: $command_name"
            missing=1
        }
    done

    ((missing == 0)) || die "Install prerequisites are not satisfied."
}

load_source_config() {
    # Read the shipped configuration for the values the installer needs.
    # The installed copy is authoritative once it exists.
    local config="${PREFIX}/data/config.conf"

    [[ -f "$config" ]] || config="${SRC_DIR}/data/config.conf"

    # shellcheck disable=SC1090
    source "$config"

    STUDENT_GROUP="${STUDENT_GROUP:-students}"
    FACULTY_GROUP="${FACULTY_GROUP:-faculty}"
    SUBMISSION_ROOT="${SUBMISSION_ROOT:-/srv/submissions}"
    SUBMISSION_ROOT_MODE="${SUBMISSION_ROOT_MODE:-0711}"
    SUBMIT_BIN="${SUBMIT_BIN:-/usr/local/bin/submit}"
    SUBMIT_STORE_HELPER="${SUBMIT_STORE_HELPER:-/usr/local/libexec/asms-store}"
}

# ---------------------------------------------------------------------------
# Installation steps
# ---------------------------------------------------------------------------

create_groups() {
    step "Groups"

    local group
    for group in "$STUDENT_GROUP" "$FACULTY_GROUP"; do
        if getent group "$group" >/dev/null; then
            success "Group already exists: $group"
            continue
        fi

        if ((CHECK_ONLY)); then
            info "Would create group: $group"
            continue
        fi

        groupadd "$group"
        success "Created group: $group"
    done
}

create_directories() {
    step "Directory layout"

    local entry relative mode path

    for entry in "${PREFIX_DIRS[@]}"; do
        relative="${entry%%:*}"
        mode="${entry##*:}"

        if [[ -n "$relative" ]]; then
            path="${PREFIX}/${relative}"
        else
            path="$PREFIX"
        fi

        if ((CHECK_ONLY)); then
            [[ -d "$path" ]] && info "Exists: $path" || info "Would create: $path ($mode)"
            continue
        fi

        install -d -o root -g root -m "$mode" "$path"
    done

    ((CHECK_ONLY)) || success "Layout ready under $PREFIX"

    # The authoritative submission archive lives outside PREFIX.
    #
    # 0711 lets a student traverse to their own archive by exact name while
    # making the directory unlistable, so no student can discover another
    # student's account this way.
    if ((CHECK_ONLY)); then
        info "Would ensure: $SUBMISSION_ROOT (root:root $SUBMISSION_ROOT_MODE)"
    else
        install -d -o root -g root -m "$SUBMISSION_ROOT_MODE" "$SUBMISSION_ROOT"
        success "Submission root ready: $SUBMISSION_ROOT (root:root $SUBMISSION_ROOT_MODE)"
    fi
}

install_modules() {
    step "Modules"

    local module
    for module in "${MODULES[@]}"; do
        if ((CHECK_ONLY)); then
            info "Would install: modules/${module}"
            continue
        fi

        install -o root -g root -m 0750 \
            "${SRC_DIR}/${module}" "${PREFIX}/modules/${module}"
    done

    ((CHECK_ONLY)) && return 0

    success "Installed ${#MODULES[@]} modules to ${PREFIX}/modules"
}

install_admin() {
    step "Administration interface"

    if ((CHECK_ONLY)); then
        info "Would install: ${PREFIX}/assignment-admin"
        info "Would link:    /usr/local/sbin/assignment-admin"
        return 0
    fi

    install -o root -g root -m 0750 \
        "${SRC_DIR}/assignment-admin" "${PREFIX}/assignment-admin"

    install -o root -g root -m 0644 \
        "${SRC_DIR}/VERSION" "${PREFIX}/VERSION"

    local doc
    for doc in README.md CHANGELOG.md; do
        [[ -f "${SRC_DIR}/${doc}" ]] || continue
        install -o root -g root -m 0644 "${SRC_DIR}/${doc}" "${PREFIX}/${doc}"
    done

    # A stable entry point on root's PATH.
    install -d -o root -g root -m 0755 /usr/local/sbin
    ln -sfn "${PREFIX}/assignment-admin" /usr/local/sbin/assignment-admin

    success "assignment-admin installed (run: sudo assignment-admin)"
}

install_templates() {
    [[ -d "${SRC_DIR}/templates" ]] || return 0

    step "Templates"

    if ((CHECK_ONLY)); then
        info "Would install shell/editor templates"
        return 0
    fi

    local template
    while IFS= read -r -d '' template; do
        install -o root -g root -m 0644 \
            "$template" "${PREFIX}/templates/$(basename "$template")"
    done < <(find "${SRC_DIR}/templates" -maxdepth 1 -type f -print0)

    success "Templates installed"
}

# Configuration is never clobbered: an administrator's edits outlive an
# upgrade. New keys introduced by a newer release are reported so they can be
# merged deliberately.
install_config() {
    step "Configuration"

    local target="${PREFIX}/data/config.conf"
    local source="${SRC_DIR}/data/config.conf"

    if [[ ! -f "$target" ]]; then
        if ((CHECK_ONLY)); then
            info "Would install fresh config: $target"
            return 0
        fi

        install -o root -g root -m 0640 "$source" "$target"
        success "Installed configuration: $target"
        return 0
    fi

    info "Keeping existing configuration: $target"

    # Report keys present in the shipped config but absent from the installed
    # one. Compare assignment names only; values are the administrator's.
    local new_keys=()
    local key

    while IFS= read -r key; do
        grep -Eq "^[[:space:]]*${key}=" "$target" || new_keys+=("$key")
    done < <(grep -Eo '^[A-Z_][A-Z0-9_]*=' "$source" | tr -d '=' | sort -u)

    if ((${#new_keys[@]} > 0)); then
        warn "This release adds ${#new_keys[@]} configuration key(s) not in your config:"
        printf '         %s\n' "${new_keys[@]}"
        warn "Defaults apply until you add them. Reference: ${source}"
    else
        success "Configuration is up to date"
    fi
}

# The submit command is a setuid-root binary plus a root-only helper.
#
# It has to be a compiled binary: Linux ignores the setuid bit on interpreted
# scripts, so a setuid shell script would silently run unprivileged.
install_submit() {
    step "Submit command"

    local csource="${SRC_DIR}/submit/asms-submit.c"
    local helper="${SRC_DIR}/submit/asms-store"

    if [[ ! -f "$csource" || ! -f "$helper" ]]; then
        warn "submit sources not present in this tree; skipping."
        warn "  expected: submit/asms-submit.c and submit/asms-store"
        warn "  verify_server.sh will report submit as missing until installed."
        return 0
    fi

    if ! command -v gcc >/dev/null 2>&1; then
        warn "gcc is not installed; cannot build submit."
        warn "Run the development environment installer, then re-run install.sh."
        return 0
    fi

    if ((CHECK_ONLY)); then
        info "Would build and install: $SUBMIT_BIN (setuid root)"
        info "Would install:           $SUBMIT_STORE_HELPER (root only)"
        return 0
    fi

    BUILD_DIR="$(mktemp -d)"

    # The archive path, helper path and student group are compiled in rather
    # than read at runtime: a setuid binary must not take its security
    # parameters from anything the caller can influence.
    #
    # Built with -Werror first, matching the build command documented in
    # asms-submit.c's own header: this is a setuid-root binary, and a warning
    # from a stricter compiler (a signed/unsigned comparison, an implicit
    # conversion) is exactly the kind of thing that should stop an install
    # and get a human to look, not compile silently into the binary that
    # runs as root. Only if that strict build fails do we fall back to a
    # plain build, so a compiler upgrade does not leave a server with no
    # submit command at all -- but the fallback is loud, because at that
    # point the binary being installed has not passed its own documented bar.
    local cflags=(-O2 -Wall -Wextra -Werror)
    local gcc_log="${BUILD_DIR}/gcc.log"

    if ! gcc "${cflags[@]}" \
        -DASMS_STORE_HELPER="\"${SUBMIT_STORE_HELPER}\"" \
        -DASMS_STUDENT_GROUP="\"${STUDENT_GROUP}\"" \
        -o "${BUILD_DIR}/submit" "$csource" 2>"$gcc_log"; then

        warn "submit failed to compile with -Werror (its documented build flags):"
        sed 's/^/         /' "$gcc_log" >&2

        cflags=(-O2 -Wall -Wextra)

        if ! gcc "${cflags[@]}" \
            -DASMS_STORE_HELPER="\"${SUBMIT_STORE_HELPER}\"" \
            -DASMS_STUDENT_GROUP="\"${STUDENT_GROUP}\"" \
            -o "${BUILD_DIR}/submit" "$csource"; then
            die "Failed to compile submit, even without -Werror."
        fi

        warn "submit was built WITHOUT -Werror because of the warnings above."
        warn "This is a setuid-root binary. Review those warnings before trusting it."
    fi

    # The helper runs as root and is exec'd by a setuid binary. Anyone able to
    # write it gains root, so it is root-owned and root-only.
    sed "s|@PREFIX@|${PREFIX}|g" "$helper" > "${BUILD_DIR}/asms-store"

    install -d -o root -g root -m 0755 "$(dirname "$SUBMIT_STORE_HELPER")"
    install -o root -g root -m 0700 "${BUILD_DIR}/asms-store" "$SUBMIT_STORE_HELPER"

    # 4755: setuid root, world-executable. Students invoke it directly.
    install -o root -g root -m 4755 "${BUILD_DIR}/submit" "$SUBMIT_BIN"

    success "Installed $SUBMIT_BIN (setuid root)"
    success "Installed $SUBMIT_STORE_HELPER (root only)"
}

# A read-only, non-setuid faculty tool: "who has submitted ASSIGNMENT".
#
# Not setuid and not installed under PREFIX/modules -- it needs no privilege
# beyond what a faculty account already has via ACLs, and PREFIX is 0700
# root-only, unreadable to the faculty this tool is for. Config values are
# baked in with sed, the same way asms-submit.c's are baked in with -D
# flags, because the installed script cannot read config.conf at runtime.
install_check_submissions() {
    step "Faculty submission checker"

    local source="${SRC_DIR}/check_submissions.sh"
    local target="/usr/local/bin/assignment-check"

    if [[ ! -f "$source" ]]; then
        warn "check_submissions.sh not present in this tree; skipping."
        return 0
    fi

    if ((CHECK_ONLY)); then
        info "Would install: $target"
        return 0
    fi

    local staged
    staged="$(mktemp)"
    sed \
        -e "s|@SUBMISSION_ROOT@|${SUBMISSION_ROOT}|g" \
        -e "s|@STUDENT_GROUP@|${STUDENT_GROUP}|g" \
        -e "s|@FACULTY_GROUP@|${FACULTY_GROUP}|g" \
        "$source" > "$staged"

    install -o root -g root -m 0755 "$staged" "$target"
    rm -f "$staged"

    success "Installed $target"
}

# Boot-time mount restoration.
#
# fstab alone is not sufficient: util-linux before 2.37 ignores `ro` on a
# single-step bind mount, so on Ubuntu 20.04 every student view would come
# back read-WRITE after a reboot. This unit re-asserts the correct state.
install_systemd_unit() {
    step "Boot-time mount enforcement"

    local unit_source="${SRC_DIR}/systemd/asms-mounts.service"
    local unit_target="/etc/systemd/system/asms-mounts.service"

    [[ -f "$unit_source" ]] || {
        warn "systemd/asms-mounts.service not present; skipping."
        return 0
    }

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd not available; skipping boot-time mount enforcement."
        warn "Student mounts will rely on /etc/fstab alone. On util-linux"
        warn "older than 2.37 they may return read-write after a reboot."
        return 0
    fi

    if ((CHECK_ONLY)); then
        info "Would install and enable: $unit_target"
        return 0
    fi

    sed "s|@PREFIX@|${PREFIX}|g" "$unit_source" > "$unit_target"
    chown root:root "$unit_target"
    chmod 0644 "$unit_target"

    systemctl daemon-reload
    systemctl enable asms-mounts.service >/dev/null 2>&1 ||
        warn "Could not enable asms-mounts.service; enable it manually."

    success "asms-mounts.service installed and enabled"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

show_summary() {
    step "Summary"

    local version="unknown"
    [[ -f "${PREFIX}/VERSION" ]] &&
        version="$(grep -E '^Version=' "${PREFIX}/VERSION" | cut -d= -f2)"

    printf '  %-22s %s\n' "ASMS version"    "$version"
    printf '  %-22s %s\n' "Install prefix"  "$PREFIX"
    printf '  %-22s %s\n' "Submission root" "$SUBMISSION_ROOT"
    printf '  %-22s %s\n' "Student group"   "$STUDENT_GROUP"
    printf '  %-22s %s\n' "Faculty group"   "$FACULTY_GROUP"
    echo

    if ((CHECK_ONLY)); then
        info "Check mode: nothing was modified."
        return 0
    fi

    success "ASMS installed."
    echo
    echo "Next steps:"
    echo "  1. sudo assignment-admin        -> Install Development Environment"
    echo "  2. sudo assignment-admin        -> Verify Server"
    echo "  3. sudo assignment-admin        -> Provision Students / Faculty"
    echo
    warn "Run Verify Server before provisioning: it reports missing"
    warn "dependencies (acl, auditd) that provisioning relies on."
    echo
    info "Faculty can check who has submitted an assignment with:"
    info "  assignment-check ASSIGNMENT"
    info "  assignment-check --list-assignments"
}

main() {
    parse_args "$@"
    require_admin_entry
    require_root
    require_source_files
    require_commands
    load_source_config

    echo "=============================================="
    echo " ASMS Installer"
    echo "=============================================="
    printf ' Source : %s\n' "$SRC_DIR"
    printf ' Prefix : %s\n' "$PREFIX"
    ((CHECK_ONLY)) && printf ' Mode   : check only (no changes)\n'
    echo "=============================================="

    create_directories
    create_groups
    install_modules
    install_admin
    install_templates
    install_config
    install_submit
    install_check_submissions
    install_systemd_unit
    show_summary
}

main "$@"
