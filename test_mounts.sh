#!/usr/bin/env bash
#
# Assignment Server Management System (ASMS)
# Self-check for the fstab handling in configure_mounts.sh.
#
# fstab edits are the part of the mount module that touches a real system
# file, where a bad regex silently breaks the machine's boot. These tests run
# against a temporary file (configure_mounts.sh reads $FSTAB) so nothing on
# this host is touched, and they need no root and no mounts.
#
# The mount operations themselves need a Linux kernel and are covered by
# integration_test.sh on the server.
#
#   ./test_mounts.sh
#

set -Eeuo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

check() {
    local label="$1" expected="$2" actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        printf '  [ OK ] %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$label"
        printf '         expected: %s\n' "$expected"
        printf '         actual  : %s\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

check_ok() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [ OK ] %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s (expected success)\n' "$label"; FAIL=$((FAIL + 1))
    fi
}

check_fails() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s (expected failure)\n' "$label"; FAIL=$((FAIL + 1))
    else
        printf '  [ OK ] %s\n' "$label"; PASS=$((PASS + 1))
    fi
}

# Enumeration stubs, as in test_utils.sh.
getent() {
    case "$1" in
        passwd)
            cat <<'EOF'
root:x:0:0:root:/root:/bin/bash
alice:x:3001:3000:Alice:/home/alice:/bin/bash
bob:x:3002:3000:Bob:/home/bob:/bin/bash
EOF
            ;;
        group)
            case "${2:-}" in
                students) echo "students:x:3000:" ;;
                faculty)  echo "faculty:x:4000:dr_smith" ;;
                *) return 2 ;;
            esac
            ;;
        *) return 2 ;;
    esac
}
export -f getent

echo "ASMS mount module self-check"
echo

export ASMS_CONFIG_FILE="${SRC_DIR}/data/config.conf"

# shellcheck source=configure_mounts.sh
source "${SRC_DIR}/configure_mounts.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

FSTAB="${WORK}/fstab"

# A realistic fstab. The unrelated lines must survive every operation --
# especially the root filesystem entry.
cat > "$FSTAB" <<'EOF'
# /etc/fstab: static file system information.
UUID=11111111-1111-1111-1111-111111111111 /     ext4  defaults        0 1
UUID=22222222-2222-2222-2222-222222222222 /boot ext4  defaults        0 2
/swap.img                                 none  swap  sw              0 0
EOF

ORIGINAL_LINES="$(wc -l < "$FSTAB")"

echo "fstab entries"

check_fails "no entry before adding" fstab_entry_exists "/srv/submissions/alice" "/home/alice/submissions"

add_fstab_entry alice
check_ok "entry exists after adding" fstab_entry_exists "/srv/submissions/alice" "/home/alice/submissions"

check "entry uses the canonical option set" \
    "/srv/submissions/alice /home/alice/submissions none bind,ro,nosuid,nodev,noexec 0 0" \
    "$(grep '^/srv/submissions/alice ' "$FSTAB")"

# Adding twice must not duplicate: provisioning is re-runnable, and a
# duplicate bind line stacks a second mount on every boot.
add_fstab_entry alice
add_fstab_entry alice
check "adding repeatedly is idempotent" "1" \
    "$(grep -c '^/srv/submissions/alice ' "$FSTAB")"

add_fstab_entry bob
check "second student added" "1" "$(grep -c '^/srv/submissions/bob ' "$FSTAB")"

echo
echo "fstab removal"

remove_fstab_entry alice
check_fails "alice's entry is gone" fstab_entry_exists "/srv/submissions/alice" "/home/alice/submissions"
check_ok    "bob's entry survives"  fstab_entry_exists "/srv/submissions/bob" "/home/bob/submissions"

# The whole point: removal must not disturb anything else in the file.
check "root filesystem line intact" "1" \
    "$(grep -c '^UUID=11111111-1111-1111-1111-111111111111 / ' "$FSTAB")"
check "boot line intact" "1" "$(grep -c '/boot' "$FSTAB")"
check "swap line intact" "1" "$(grep -c '^/swap.img' "$FSTAB")"
check "comment header intact" "1" "$(grep -c '^# /etc/fstab' "$FSTAB")"

remove_fstab_entry bob
check "file back to its original length" "$ORIGINAL_LINES" "$(wc -l < "$FSTAB")"

# Removing something absent is a no-op, not an error: removal modules call it
# unconditionally.
check_ok "removing a missing entry succeeds" remove_fstab_entry alice
check "no-op removal changed nothing" "$ORIGINAL_LINES" "$(wc -l < "$FSTAB")"

echo
echo "fstab edge cases"

# A commented-out entry must not count as present, or provisioning would skip
# adding a real one and the mount would not survive reboot.
cat > "$FSTAB" <<'EOF'
# /srv/submissions/carol /home/carol/submissions none bind,ro 0 0
EOF

check_fails "commented entry does not count as existing" \
    fstab_entry_exists "/srv/submissions/carol" "/home/carol/submissions"

add_fstab_entry carol
check "real entry added alongside the comment" "1" \
    "$(grep -c '^/srv/submissions/carol ' "$FSTAB")"

remove_fstab_entry carol
check "removal left the comment alone" "1" \
    "$(grep -c '^# /srv/submissions/carol' "$FSTAB")"

# A student whose name is a prefix of another's must not be affected.
: > "$FSTAB"
add_fstab_entry alice
add_fstab_entry alice2

remove_fstab_entry alice
check "prefix-named student unaffected by removal" "1" \
    "$(grep -c '^/srv/submissions/alice2 ' "$FSTAB")"
check "target student removed" "0" \
    "$(grep -c '^/srv/submissions/alice /' "$FSTAB")"

echo
echo "canonical mount options"

check "read-only is present"  "yes" \
    "$([[ ",${STUDENT_MOUNT_OPTIONS}," == *",ro,"* ]] && echo yes || echo no)"
check "bind is present"       "yes" \
    "$([[ ",${STUDENT_MOUNT_OPTIONS}," == *",bind,"* ]] && echo yes || echo no)"
check "nosuid is present"     "yes" \
    "$([[ ",${STUDENT_MOUNT_OPTIONS}," == *",nosuid,"* ]] && echo yes || echo no)"
check "not writable by option" "no" \
    "$([[ ",${STUDENT_MOUNT_OPTIONS}," == *",rw,"* ]] && echo yes || echo no)"

echo
echo "======================================"
printf ' Passed: %d\n' "$PASS"
printf ' Failed: %d\n' "$FAIL"
echo "======================================"

((FAIL == 0)) || exit 1

echo "Mount module self-check passed."
