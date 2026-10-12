# ASMS — Assignment Server Management System

**Version 2.0.0 "Genesis"** · Ubuntu 20.04+ / Debian 11+ · Bash + C · No web UI, SSH only

ASMS turns a Linux box into a university assignment submission server. Students
get isolated accounts with a writable working area; their submitted work is
copied into a server-side archive they cannot alter, and shown back to them
through a read-only mount. Faculty can read every submission but modify none
of them. No student can reach another student's work by any path. There is no
web dashboard — every interaction is a terminal command over SSH.

---

## Table of contents

- [Quick start](#quick-start)
- [The security model](#the-security-model)
- [Layout](#layout)
- [`assignment-admin` — the one command](#assignment-admin--the-one-command)
- [Command reference](#command-reference)
- [Faculty tool: `assignment-check`](#faculty-tool-assignment-check)
- [Faculty web page: viewing submissions](#faculty-web-page-viewing-submissions)
- [Configuration](#configuration)
- [Development environment](#development-environment)
- [Audit](#audit)
- [Backup and restore](#backup-and-restore)
- [Reboot persistence](#reboot-persistence)
- [Testing](#testing)
- [Documentation](#documentation)
- [Requirements](#requirements)

---

## Quick start

```bash
git clone <this-repo>
cd ASMS_v2.0
sudo ./assignment-admin
```

The menu walks you through it, but in order, a first run is:

1. **Install development environment** (option 8 once installed, or run
   `install_devtools.sh` directly) — compilers, editors, `acl`, `auditd`.
   `submit` is compiled at install time and needs `gcc`, so installing ASMS
   before this step will skip `submit` with a warning.
2. **Install / upgrade ASMS** — installs to `/opt/assignment-server`, compiles
   and installs the setuid `submit` binary, wires up `assignment-check`.
3. **Verify server** — confirms everything above landed correctly before you
   depend on it.
4. **Provision students / faculty** — from a CSV roster or a comma-separated
   list.

Everything after that is `sudo assignment-admin` (it's installed to
`/usr/local/sbin` too, so it's on `PATH`).

---

## The security model

Everything in ASMS exists to hold one invariant:

> Students submit from their writable assignment area and later view exactly
> their own submitted copies through a read-only mount, while having no
> access to another student's submission area.

Three directories per student:

```
/home/<student>/assignments      student-owned, 0700   ← work happens here
/home/<student>/submissions      read-only bind mount  ← view only
/srv/submissions/<student>/      root-owned, 0750      ← the real archive
```

`~/submissions` is a **view**, not storage. It is a read-only bind mount of
`/srv/submissions/<student>`. A student can list and read it; they cannot
write, delete, or replace anything through it — the kernel refuses, because
the mount itself is read-only.

The archive is owned by `root` and is never writable by any student. The only
thing that writes to it is `submit`.

### Why students cannot see each other

| Barrier | Effect |
|---|---|
| `/srv/submissions` is `0711` | Traverse-only. A student can reach their own archive by exact name but **cannot list the directory**, so other students' accounts aren't even discoverable this way. |
| `/srv/submissions/<student>` is `root:root 0750` | The group is `root`, not `students`. Group membership grants nothing. |
| ACL `u:<student>:rX` | The *only* thing granting a student read access, and it names exactly one student. |
| Bind mount is per-student | `/home/A/submissions` resolves only to `/srv/submissions/A`. There is no mount that would expose B's archive to A. |

Faculty read access comes from a separate `g:faculty:rX` ACL applied to each
student archive, plus a default ACL so new submissions inherit it. `/srv/submissions`'s
`0711` mode applies to faculty too — nobody can list it, faculty go straight
to a known student's path.

> **Note on `chmod` and ACLs.** Running `chmod` on an ACL-bearing directory
> rewrites the ACL mask and can silently void every named ACL entry — the
> student's and faculty's read access both disappear with no error. ASMS
> modules therefore set the mode at creation time with `install(1)` and apply
> ACLs afterwards; they never `chmod` an archive directory.

### How `submit` writes to a root-owned archive

`submit` is a **setuid-root compiled binary**, not a script. Linux ignores
the setuid bit on interpreted scripts, so a setuid shell script would run
unprivileged and silently fail.

```
student runs: submit assignment01 ~/assignments/assignment01
                    │
/usr/local/bin/submit  (root:root 4755, setuid)
  ├─ getuid() identifies the caller — not argv, not $USER, not the environment
  ├─ confirms the caller is in the students group
  ├─ validates the assignment name and rejects paths outside ~/assignments
  ├─ scrubs the environment
  └─ execs
        │
/usr/local/libexec/asms-store  (root:root 0700, root-writable only)
  └─ copies into /srv/submissions/<caller>/<assignment>/submission-NNN/
```

The caller's identity comes from `getuid()`, so a student cannot submit as
another student by manipulating arguments or environment. Submissions are
versioned and never overwritten, so earlier attempts survive.

`asms-store` is root-writable only, and `verify_server.sh` checks this:
anyone who can write it gains root.

### Storage limits

`MAX_SUBMISSION_BYTES`/`MAX_SUBMISSION_FILES` bound a single `submit` call,
but assignment names are arbitrary student-chosen text and versions are
never deleted, so those two alone don't stop unlimited resubmission or
unlimited distinct assignment names from filling the disk. `asms-store` also
enforces `MAX_STUDENT_ARCHIVE_BYTES` (a hard cap on one student's total
archive) and `SUBMISSION_MIN_FREE_BYTES` (a floor on free space for the
filesystem hosting `SUBMISSION_ROOT`) before accepting any submission. For a
real cohort, put `SUBMISSION_ROOT` on its own filesystem with OS-level
quotas too — these checks are a backstop, not a substitute.

---

## Layout

### This repository

```
ASMS_v2.0/
├── assignment-admin      the single entry point — run this, not anything in scripts/
├── VERSION
├── scripts/               every module (install.sh, provision_*.sh, remove_*.sh,
│                           configure_mounts.sh, verify_server.sh, backup/restore,
│                           check_submissions.sh, the test_*.sh suite, ...)
├── submit/                asms-submit.c (setuid shim) + asms-store (root helper)
├── systemd/               asms-mounts.service (boot-time mount enforcement),
│                           asms-web.service (faculty web page)
├── web/                   asms-web (read-only faculty web page, Python stdlib)
├── data/config.conf       the single source of truth for shared values
├── docs/                  student_guide.md, faculty_guide.md
├── README.md / CHANGELOG.md
```

`assignment-admin` stays at the repository root — it's the one file you're
ever told to run directly (`sudo ./assignment-admin`) — while every module it
drives lives together in `scripts/`. Nothing else needs to know or care that
the split exists: `install.sh` resolves module paths relative to `scripts/`
and everything else (its own repo root, `data/`, `submit/`, `systemd/`)
relative to one level up, and `assignment-admin` resolves `scripts/` the same
way it already resolved the installed `modules/` directory.

### Installed (`/opt/assignment-server`)

```
/opt/assignment-server/
├── assignment-admin          menu interface (also /usr/local/sbin/)
├── VERSION
├── modules/                  all functional modules, 0750
├── data/config.conf          the single source of truth for shared values
├── credentials/              0700, root only — generated passwords live here
├── logs/                     0700, root only
├── backups/
└── archive/semesters/        previous semesters' submissions

/srv/submissions/                    authoritative archive, 0711
/usr/local/bin/submit                setuid-root shim (4755)
/usr/local/libexec/asms-store        root-only store helper (0700)
/usr/local/bin/assignment-check      faculty submission-status tool, not setuid (0755)
/usr/local/libexec/asms-web          faculty web page, runs as asms-web (0755)
/etc/asms-web/                       its TLS certificate and key (0750 root:asms-web)
```

`/opt/assignment-server` itself is `0700 root:root` — nothing under it is
readable by anyone but root, including faculty. Any tool meant for
non-root use (like `assignment-check`) is installed *outside* that tree for
exactly this reason. Note that `scripts/` in the repository becomes
`modules/` once installed — `install.sh` renames the destination, not the
source layout.

### Student enumeration

Students are created with `students` as their **primary** group. Primary
group membership does **not** appear in the member field of `/etc/group`, so
`getent group students` returns an empty member list no matter how many
students exist.

Always use `get_student_users()` from `utils.sh`. It reads `getent passwd`
and matches on primary GID as well as supplementary membership. Modules must
not implement their own enumeration.

---

## `assignment-admin` — the one command

There is a single entry point. You never need to remember a second one.

```bash
sudo ./assignment-admin
```

`assignment-admin` detects where it is and adapts:

- **From this source directory**, before installation: it offers to install,
  to preview an install, and to run the tests. Once installation finishes it
  hands straight over to the installed copy — no second command.
- **Once installed** (`/opt/assignment-server`, and on your `PATH` as
  `assignment-admin`): the full menu, covering every module.

```
Setup                                Accounts        Submissions
  1. Install / upgrade ASMS            1. Provision students    5. Configure mounts
  2. Preview installation              2. Provision faculty     6. Verify mounts
Manage                                 3. Remove students       7. Repair mounts
  3. Open installed admin menu         4. Remove faculty
Tests                                System              Data
  4. Offline self-tests                 8. Dev environment      12. Backup
  5. Full integration test              9. Audit rules          13. Restore
                                       10. Verify server        14. Semester reset
        (source mode)                  11. Security check      (installed mode)
                                       15. System information
                                       16. View activity log
```

Flags, for scripting or a quick check:

```bash
sudo ./assignment-admin --install   # install, then open the menu
sudo ./assignment-admin --check     # dry run: report changes, make none
./assignment-admin --test           # offline self-tests (no root needed)
sudo assignment-admin --verify      # server verification; exits 0 or 1
```

`install.sh` still exists and works on its own if you prefer it — the menu
just calls it. It is idempotent: re-running upgrades modules but never
overwrites configuration, credentials, logs, backups, or submissions, and it
reports new configuration keys rather than merging them silently.

---

## Command reference

Every module can be driven directly instead of through the menu — useful for
scripting or automation. In this repository they live in `scripts/` (e.g.
`scripts/provision_students.sh`); once installed they're at
`/opt/assignment-server/modules/`. Each one also shows this same table with
`-h`/`--help`. With no options, every module opens its own interactive menu.

### `install.sh`

Installs the source tree into `/opt/assignment-server`, compiles `submit`,
installs `assignment-check`, and wires up `assignment-admin`.

| Option | Effect |
|---|---|
| `--prefix PATH` | Installation root (default: `/opt/assignment-server`) |
| `--check` | Report what would change, modify nothing |
| `-h`, `--help` | Show help |

### `provision_students.sh`

Creates student accounts: home directory, `~/assignments`, the read-only
`~/submissions` mount, the archive, and ACLs.

| Option | Effect |
|---|---|
| `--csv FILE` | Provision from a CSV roster (`username[,name[,password]]`) |
| `--users a,b,c` | Provision the named accounts |
| `--demo PREFIX COUNT` | Provision `COUNT` demo accounts named `PREFIX01`, `PREFIX02`... |
| `-h`, `--help` | Show help |

Generated passwords are written only to the root-only credentials file
(`credentials/student_credentials.csv`) — never to the terminal, admin log,
or audit log. Every new account is forced to change its password at first
login.

### `provision_faculty.sh`

Creates faculty accounts (faculty group is supplementary, not primary).

| Option | Effect |
|---|---|
| `--csv FILE` | Provision from a CSV file (`username[,display name]`) |
| `--users a,b,c` | Provision the named accounts |
| `-h`, `--help` | Show help |

### `remove_students.sh`

The single implementation of student removal — `reset_semester.sh` calls
this rather than reimplementing it.

| Option | Effect |
|---|---|
| `--users a,b,c` | Remove the named students |
| `--all` | Remove every student account |
| `--demo` | Remove demo/test accounts only (pattern match **and** anything not on the uploaded roster) |
| `--keep-archive` | Required with a selection: keep submitted work under `SUBMISSION_ROOT` |
| `--delete-archive` | Required with a selection: permanently delete submitted work |
| `-h`, `--help` | Show help |

`ASMS_ASSUME_YES=1` skips confirmation prompts — this is how
`reset_semester.sh` drives it non-interactively.

### `remove_faculty.sh`

| Option | Effect |
|---|---|
| `--users a,b,c` | Remove the named faculty accounts |
| `--all` | Remove every faculty account |
| `-h`, `--help` | Show help |

### `configure_mounts.sh`

**The** authority on the student submission archive, ACLs, `/etc/fstab`
entries, and the read-only bind mount. Every other module that needs any of
this calls into here rather than duplicating it.

| Option | Effect |
|---|---|
| `--configure USER` | Archive, ACLs, fstab entry, and mount for one student |
| `--configure-all` | The same for every student |
| `--verify-all` | Report on every student's mount (changes nothing) |
| `--repair-all` | Restore any mount that is missing or not read-only |
| `--remove USER` | Unmount and drop the fstab entry (archive is kept) |
| `--mount USER` | Mount only |
| `--unmount USER` | Unmount only |
| `-h`, `--help` | Show help |

### `verify_server.sh`

Read-only health and consistency checks. Changes nothing, ever.

| Option | Effect |
|---|---|
| *(none)* | Full report |
| `--security` | Security checks only |
| `--quiet` | Print the summary and failures only |
| `-h`, `--help` | Show help |

Exit status is `0` when nothing failed, `1` otherwise — suitable for cron or
a monitoring check.

### `backup_system.sh`

Creates `tar.gz` backups with a SHA-256 manifest.

| Option | Effect |
|---|---|
| `--full` | Configuration, credentials, submissions, and logs |
| `--config` | Configuration only |
| `--submissions` | Student submissions only |
| `--credentials` | Credential files only |
| `--list` | List existing backups |
| `-h`, `--help` | Show help |

### `restore_backup.sh`

| Option | Effect |
|---|---|
| `--list` | List available backups |
| `--verify ARCHIVE` | Check an archive's integrity, restore nothing |
| `--restore ARCHIVE` | Restore from `ARCHIVE` (basename, not a path) |
| `--components a,b,c` | Which components to restore: `configuration`, `credentials`, `submissions`, `logs` (default: all present) |
| `-h`, `--help` | Show help |

### `reset_semester.sh`

Controlled semester transition: archives submissions, then removes every
student account via `remove_students.sh`.

| Option | Effect |
|---|---|
| `--confirm` | Proceed without the interactive confirmation prompt (for scripted use) |
| `-h`, `--help` | Show help |

### `generate_audit.sh`

Generates and loads `auditd` rules recording student execution of sensitive
commands.

| Option | Effect |
|---|---|
| `--generate` | Generate and load student audit rules |
| `--show` | Show the current rule file and live rules |
| `--remove` | Remove ASMS audit rules |
| `-h`, `--help` | Show help |

### `install_devtools.sh`

Installs the standard programming-lab environment: compilers, editors, and
ASMS's own runtime dependencies (`acl`, `auditd`). See
[Development environment](#development-environment) for the full package
list. No options — it installs everything in one pass.

### `integration_test.sh`

Exercises the whole system end to end on a real server. See
[Testing](#testing).

| Option | Effect |
|---|---|
| `--with-reset` | Include the semester-reset stage (removes **ALL** student accounts) |
| `--cleanup` | Remove this test's accounts and exit |
| `-h`, `--help` | Show help |

### `check_submissions.sh` (installed as `assignment-check`)

See [Faculty tool: assignment-check](#faculty-tool-assignment-check) below.

---

## Faculty tool: `assignment-check`

Faculty can check who has submitted a given assignment across the **whole
class** in one command, instead of checking students one at a time by hand.

```bash
$ assignment-check assignment01
STUDENT            STATUS         VERSIONS   LATEST
-------            ------         --------   ------
bt25cse001         NOT submitted  -          -
bt25cse007         submitted      1          submission-001
...

Submitted: 4 / 123

$ assignment-check --list-assignments
assignment01
```

| Option | Effect |
|---|---|
| `ASSIGNMENT` | List every student's submission status for `ASSIGNMENT` |
| `--list-assignments` | List distinct assignment names seen across the class |
| `-h`, `--help` | Show help |

It's read-only, faculty-only (refuses students and non-faculty immediately),
and grants no new access — it just automates checking the roster against the
same `g:faculty:rX` ACL faculty already have. It's installed to
`/usr/local/bin/assignment-check` (`0755`, **not** setuid) rather than into
`modules/`, because `/opt/assignment-server` is `0700` root-only and
therefore unreadable to the faculty accounts this tool exists for. Its
configuration is baked in with `sed` at install time, the same way
`asms-submit.c`'s constants are baked in with `-D` compiler flags.

---

## Faculty web page: viewing submissions

Faculty who would rather not use a terminal can view submissions in any
browser:

```
https://<server>:8443/
```

They sign in with their normal server username and password. Students are
refused even with a correct password, and five wrong passwords lock that
username out of the page for five minutes.

The page uses large text and big buttons and only shows work; nothing on it
changes anything. Faculty choose an assignment, then a student (the list
shows how many attempts each made and when they last submitted), and press
**View submission**. That page lists every attempt, a table of the attempt's
files with sizes, and then the full contents of each text file. Any file,
including PDFs and other binary files, can be downloaded; downloads are never
opened inside the page, so a submitted `.html` file cannot run there. Older
attempts can be opened for comparison.

**Certificate.** The installer creates a self-signed certificate, so browsers
warn on the first visit. To avoid that, replace `/etc/asms-web/tls.crt` and
`tls.key` with a real certificate and run `systemctl restart asms-web`.

**Firewall.** If one is running, open the port: `ufw allow 8443/tcp`. The
port is `WEB_PORT` in `data/config.conf` (default `8443`); re-run the
installer after changing it.

**How it runs.** `asms-web.service` runs as an unprivileged `asms-web`
account with no password, shell, or home. It gets two supplementary groups
from the systemd unit, not from `/etc/group`: `faculty`, for the same
`g:faculty:rX` read access faculty already have, and `shadow`, so PAM can
check passwords (through `/etc/pam.d/asms-web`, which includes the normal
`common-auth` and `common-account`). Because the groups are not in
`/etc/group`, the account never counts as faculty and Remove Faculty can
never touch it. The whole filesystem is read-only to it. Its TLS key lives
in `/etc/asms-web/`, outside `/opt/assignment-server`, which is root-only.
Problems show up in `journalctl -u asms-web`.

---

## Configuration

`data/config.conf` defines every shared value — groups, paths, permission
modes, mount options, password length, submission limits, audit commands,
backup signing, demo-account detection. Modules read it once via
`load_config()` in `utils.sh` and must not redefine values afterwards.
Change behaviour there, not in module source.

`install.sh` never overwrites an existing `config.conf` on upgrade — your
local edits survive. New keys introduced by an upgrade are reported, not
merged in silently.

Key values:

| Key | Meaning |
|---|---|
| `STUDENT_GROUP` / `FACULTY_GROUP` | Linux groups (`students`, `faculty`) |
| `SUBMISSION_ROOT` | Authoritative archive root (`/srv/submissions`) |
| `PROTECTED_ACCOUNTS` | Accounts removal/reset modules must always refuse to touch |
| `MAX_SUBMISSION_BYTES` / `MAX_SUBMISSION_FILES` | Per-`submit`-call limits |
| `MAX_STUDENT_ARCHIVE_BYTES` / `SUBMISSION_MIN_FREE_BYTES` | Aggregate limits, see [Storage limits](#storage-limits) |
| `STUDENT_ROSTER_CSV` | Path to the uploaded class roster, used to catch off-roster test accounts |
| `DEMO_ACCOUNT_PATTERN` | Regex used by `remove_students.sh --demo` |
| `BACKUP_GPG_KEY_ID` | Optional — enables tamper-evident backup signing |

---

## Development environment

`install_devtools.sh` installs the standard programming-lab toolchain in one
pass (Ubuntu/Debian, via `apt`):

| Category | Packages |
|---|---|
| ASMS runtime dependencies | `acl`, `auditd`, `audispd-plugins` |
| Editors | `nano`, `vim`, `neovim`, `emacs-nox`, `joe`, `micro` |
| C/C++ | `build-essential`, `gcc`, `g++`, `make`, `cmake`, `gdb`, `valgrind` |
| Java | `default-jdk` |
| Python | `python3`, `python3-pip`, `python3-venv` |
| Version control / networking | `git`, `curl`, `wget` |
| Utilities | `tree`, `zip`, `unzip`, `less`, `htop`, `jq`, `ripgrep`, `fd-find`, `shellcheck` |

`acl` and `gcc` are hard requirements, not conveniences: without `acl`,
nobody can read a submission archive; without `gcc`, `submit` cannot be
compiled at install time.

Everything here is a plain terminal tool — no GUI, so all of it works over a
bare SSH session. (`gdb` is CLI-only and works fine over SSH; if you ever add
a GUI debugger front-end, remember it will need X11 forwarding, which ASMS
does not set up.)

Not installed by default, but easy to add the same way (`apt install ...`):
Clang/LLVM (`clang`, `clang++`), alternate GCC versions, Rust, Go.

---

## Audit

Rules are generated against the students **GID**, not per-UID. Students have
`students` as their primary group, so a GID match covers exactly the student
population and excludes faculty, admin, and service accounts. It also keeps
the ruleset a constant size instead of growing by ~20 rules per enrolled
student.

```bash
ausearch -k student_cmd_submit
ausearch -k student_cmd_rm
ausearch -k student_cmd_cp
```

Rules are regenerated automatically whenever student membership changes
(provisioning, removal, semester reset).

---

## Backup and restore

Backups are `tar.gz` archives under `/opt/assignment-server/backups/`
containing configuration, credentials, submissions, and logs, with a
`MANIFEST.sha256` that hashes the data files **but not itself**.

Restore verifies the manifest, creates a safety copy of current data first,
and touches only ASMS-owned paths. It never restores `/etc/passwd`,
`/etc/shadow`, or arbitrary paths from an archive into `/`; `/etc/fstab` is
edited surgically to replace only ASMS mount lines. Archive extraction
refuses absolute paths, `../` traversal, and symlink-typed entries before
anything is written to disk.

### Signing (recommended before backups leave this host)

The `.sha256` sidecar next to each archive is generated by the same process
that writes the archive — it proves the file wasn't corrupted, not that it
wasn't substituted by anyone who can write to `backups/` or intercept a copy
made for off-site storage. Restoring a backup reinstalls the ASMS code
itself and runs it as root, so that distinction matters.

Set `BACKUP_GPG_KEY_ID` in `data/config.conf` to a key your backup process
can sign with, and `backup_system.sh` will produce a detached signature
(`<archive>.sha256.asc`) that `restore_backup.sh` verifies before trusting
the archive. Left unset, backups still work but stay corruption-evident
only — both tools say so explicitly rather than silently.

---

## Reboot persistence

Every student mount gets an `/etc/fstab` entry at provisioning time:

```
/srv/submissions/alice /home/alice/submissions none bind,ro,nosuid,nodev,noexec 0 0
```

> util-linux before 2.37 (Ubuntu 20.04 and older) ignores `ro` on a
> single-step bind mount and mounts it **read-write**. `configure_mounts.sh`
> always verifies the resulting mount and issues an explicit
> `mount -o remount,bind,ro` when the kernel did not honour it, so the mount
> is read-only on both old and new releases.

Verify after a reboot with **Verify Server** (`verify_server.sh`), which
checks that every student mount exists, points at that student's own
archive, and is actually read-only.

---

## Testing

Offline self-tests, plus one full system test.

```bash
./scripts/test_utils.sh              # shared library: enumeration, passwords, validation
./scripts/test_mounts.sh             # fstab editing, against a temp file
./scripts/test_remove_students.sh    # removal accounting: archive outcomes, target resolution
./scripts/test_check_submissions.sh  # assignment-check: enumeration, validation, reporting
sudo ./scripts/integration_test.sh   # the whole system, on a real server
```

The first four need no root and no Linux-specific features — they stub
`getent`/`id` and, where relevant, point the module under test at a
temporary `fstab` or archive directory, so they run anywhere bash does and
touch nothing on the host. Run them after any change to the module they
cover. `assignment-admin`'s "Offline self-tests" menu option runs all four.

`integration_test.sh` is the one that proves the security model. It creates
`asmstest_alice`, `asmstest_bob`, and `asmstest_prof`, then uses `runuser` to
act as each of them — so it tests what the kernel actually permits, not what
the configuration intends:

- student A submits, resubmits, and cannot alter either version
- student A cannot read, list, write, or delete anything of student B's
- student A cannot submit into student B's archive via a path argument
- `submit` rejects traversal, slashes, sources outside `~/assignments`,
  symlinks (a symlink is a request for root to read a file the student
  cannot), and submissions from root
- faculty can read both students' work and modify neither
- audit rules cover the students group and not faculty
- a backup verifies, and its manifest does not list itself
- an unmounted view is restored read-only by the repair path

**Run it on a test machine.** It creates and deletes accounts, and
`--with-reset` removes every student account on the host.

```bash
sudo ./scripts/integration_test.sh                # everything except semester reset
sudo ./scripts/integration_test.sh --with-reset    # including semester reset
sudo ./scripts/integration_test.sh --cleanup       # remove test accounts and exit
```

Any failure naming isolation, read-only enforcement, or archive ownership
means the invariant at the top of this file is not holding.

---

## Documentation

Full walkthroughs with real captured terminal output live in [`docs/`](docs/):

- [`docs/student_guide.md`](docs/student_guide.md) — logging in, writing and
  submitting assignments, viewing past submissions, common errors
- [`docs/faculty_guide.md`](docs/faculty_guide.md) — accessing submissions,
  verifying integrity, checking whole-class submission status with
  `assignment-check`, common errors

---

## Requirements

- Ubuntu 20.04+ / Debian 11+
- root access
- `acl`, `auditd`, `gcc` (installed by the development environment module)
- `python3` and `openssl` for the faculty web page (present on a standard
  Ubuntu/Debian install)

`shellcheck` is installed with the development environment; the Definition of
Done requires the modules to pass it.
