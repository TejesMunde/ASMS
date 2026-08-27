#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Module: install_devtools.sh
# Version: 2.0.0
#
# Installs the standard programming-lab development environment.
#
# This module is intentionally Ubuntu/Debian-oriented because the server
# environment currently uses apt.
#

set -Eeuo pipefail

ASMS_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils.sh
source "${ASMS_MODULE_DIR}/utils.sh"
# shellcheck source=logger.sh
source "${ASMS_MODULE_DIR}/logger.sh"

require_root
load_config

APT_PACKAGES=(
    # ASMS runtime dependencies.
    #
    # These are not developer conveniences: without them ASMS is broken.
    #   acl     -- setfacl/getfacl. Provisioning grants a student read access
    #              to their own archive with an ACL. Without it, students
    #              cannot read their own submissions and faculty cannot read
    #              any. The scaffold used setfacl but never installed it.
    #   auditd  -- auditctl/augenrules for student command auditing.
    #   gcc     -- install.sh compiles the setuid submit binary. Also in the
    #              compiler section below; listed here as a hard requirement.
    acl
    auditd
    audispd-plugins

    # Editors
    nano
    vim
    neovim
    emacs-nox
    joe
    micro

    # C/C++
    build-essential
    gcc
    g++
    make
    cmake
    gdb
    valgrind

    # Java
    default-jdk

    # Python
    python3
    python3-pip
    python3-venv

    # Version control / networking
    git
    curl
    wget

    # Utilities
    tree
    zip
    unzip
    less
    htop
    jq
    ripgrep
    fd-find
    shellcheck
)

# Some package names can differ between distributions. We only proceed
# automatically on Debian/Ubuntu systems with apt available.
check_platform() {
    command -v apt-get >/dev/null 2>&1 || {
        error "apt-get is not available. This module currently supports Ubuntu/Debian."
        return 1
    }

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                return 0
                ;;
            *)
                warn "Detected OS: ${PRETTY_NAME:-unknown}"
                warn "This module was designed for Ubuntu/Debian."
                confirm "Continue anyway?" || return 1
                ;;
        esac
    fi
}

show_package_plan() {
    header "Development Environment"

    echo "The following packages will be installed/updated:"
    echo

    printf '  %s\n' "${APT_PACKAGES[@]}"

    echo
}

install_packages() {
    info "Updating package lists..."

    if ! apt-get update; then
        error "apt-get update failed."
        log_action "INSTALL_DEVTOOLS" "apt-update" "FAILED"
        return 1
    fi

    info "Installing development environment..."

    if DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "${APT_PACKAGES[@]}"; then
        log_action "INSTALL_DEVTOOLS" "development-environment" "SUCCESS"
        success "Development environment installed."
    else
        log_action "INSTALL_DEVTOOLS" "development-environment" "FAILED"
        error "Package installation failed."
        return 1
    fi
}

MISSING_REQUIRED=0
MISSING_OPTIONAL=0

# `failures=$((failures + 1))` rather than `((failures++))`: post-increment
# evaluates to the OLD value, so the first increment from zero returns 0 and
# reports failure, which under `set -e` can abort the script mid-report.
verify_command() {
    local command_name="$1"
    local required="${2:-optional}"

    if command -v "$command_name" >/dev/null 2>&1; then
        printf '  %-14s %s\n' "$command_name" "$(command -v "$command_name")"
        return 0
    fi

    if [[ "$required" == "required" ]]; then
        printf '  %-14s %s\n' "$command_name" "MISSING (required by ASMS)"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        printf '  %-14s %s\n' "$command_name" "missing"
        MISSING_OPTIONAL=$((MISSING_OPTIONAL + 1))
    fi

    return 0
}

verify_installation() {
    header "Verification"

    # ASMS does not work without these.
    echo "ASMS dependencies:"
    verify_command setfacl    required
    verify_command getfacl    required
    verify_command auditctl   required
    verify_command augenrules required
    verify_command gcc        required

    echo
    echo "Editors:"
    local command_name
    for command_name in nano vim nvim emacs joe micro; do
        verify_command "$command_name"
    done

    echo
    echo "Compilers and build:"
    for command_name in g++ make cmake gdb valgrind; do
        verify_command "$command_name"
    done

    echo
    echo "Languages:"
    for command_name in python3 pip3 java javac; do
        verify_command "$command_name"
    done

    echo
    echo "Tools:"
    for command_name in git curl wget tree zip unzip less htop jq rg fdfind shellcheck; do
        verify_command "$command_name"
    done

    echo

    if ((MISSING_REQUIRED > 0)); then
        error "${MISSING_REQUIRED} ASMS dependency/dependencies are missing."
        error "Provisioning and submission will not work correctly."
        log_action "INSTALL_DEVTOOLS" "verification" "MISSING_REQUIRED=${MISSING_REQUIRED}"
        return 1
    fi

    if ((MISSING_OPTIONAL > 0)); then
        warn "${MISSING_OPTIONAL} optional tool(s) are not installed."
    fi

    success "All ASMS dependencies are present."

    # submit is compiled at install time, so a freshly installed gcc means
    # install.sh should be re-run to produce it.
    if [[ ! -x "${SUBMIT_BIN}" ]]; then
        echo
        warn "The submit command is not installed yet."
        warn "Re-run install.sh now that gcc is available:  sudo ./install.sh"
    fi

    return 0
}

main() {
    check_platform

    show_package_plan

    if ! confirm "Install/update this development environment?"; then
        info "Installation cancelled."
        log_action "INSTALL_DEVTOOLS" "development-environment" "CANCELLED"
        return 0
    fi

    install_packages
    verify_installation
}

main "$@"
