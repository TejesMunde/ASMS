# Changelog

All notable changes to ASMS are recorded here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### 2026-08-27 — Repository layout: `scripts/`

- **All `.sh` modules moved into `scripts/`.** Previously every module sat
  directly in the repository root alongside `README.md`, `docs/`, `submit/`,
  and so on -- 21 script files cluttering the top level. They now live
  together under `scripts/` (`scripts/install.sh`,
  `scripts/provision_students.sh`, `scripts/test_utils.sh`, etc.).
  `assignment-admin` deliberately stays at the repository root: it is the
  one file anyone is ever told to run directly (`sudo ./assignment-admin`),
  and it still detects source vs. installed mode the same way it always
  did -- it just resolves the source-mode module directory to `scripts/`
  instead of its own directory now, the same as it already resolved the
  installed layout to `modules/`. No installed-server behaviour changes:
  `install.sh` still stages everything into `/opt/assignment-server/modules/`
  exactly as before, and `data/`, `submit/`, `systemd/`, and `docs/` are
  untouched. `install.sh` gained a `REPO_ROOT` (one level above `scripts/`)
  for the few things it installs that live outside `scripts/` --
  `assignment-admin`, `VERSION`, `data/config.conf`, `submit/`, `systemd/`,
  `templates/`. The three test scripts that resolve their own config path
  (`test_utils.sh`, `test_mounts.sh`, `test_remove_students.sh`) needed the
  same one-level-up fix; `test_check_submissions.sh` was unaffected, since
  `check_submissions.sh` is self-contained and never sources `utils.sh`.
  Verified with the full offline suite (135/135 assertions) plus a
  standalone simulation of `assignment-admin`'s mode detection and
  `install.sh`'s `require_source_files` against the real moved tree.

### 2026-08-19 — Faculty tooling, hardening follow-through, and docs

- **Added `check_submissions.sh` (`assignment-check`).** Faculty previously
  had to check submission status one student at a time, by hand, with no
  way to see coverage across the whole class. `assignment-check ASSIGNMENT`
  now lists every student's status, version count and latest version in
  one command; `assignment-check --list-assignments` lists every distinct
  assignment name seen so far. Needs no new privilege -- it runs as the
  calling faculty account and relies entirely on the `g:faculty:rX` ACL
  already granted on each student's archive. Installed to
  `/usr/local/bin/assignment-check`, not `modules/`, and deliberately not
  setuid; see `README.md` for why it can't source `utils.sh` like every
  other module does (`/opt/assignment-server` is 0700 root-only, following
  the hardening below).
- **`/opt/assignment-server` tightened from 0755 to 0700.** Any local
  account could previously run `ls /opt/assignment-server` and see the
  names of `credentials/`, `logs/`, `backups/` and every module, even
  though none of the contents were reachable. Now only root can see the
  directory exists at all. This is what forced `assignment-check` to be
  self-contained rather than sourcing `utils.sh`.
- **`remove_students.sh` archive-outcome accounting fixed.** Requesting
  removal of a nonexistent account with `--delete-archive` used to report
  "Archives: deleted" -- derived from whether deletion was *requested*, not
  from what actually happened. `show_summary()` now reports real counters
  (`ARCHIVES_DELETED`/`ARCHIVES_NOT_FOUND`/`ARCHIVE_DELETE_FAILED`/
  `ARCHIVES_KEPT`), and destructive confirmation now happens *after*
  invalid/nonexistent IDs are identified and reported, never before.
- **`remove_students.sh`'s "Remove demo/test accounts" now also
  cross-checks the class roster** (`STUDENT_ROSTER_CSV`), not just
  `DEMO_ACCOUNT_PATTERN`, so a hand-provisioned test account is found
  regardless of what it was named.
- Added `docs/student_guide.md` and `docs/faculty_guide.md`, with
  screenshot placeholders and real terminal transcripts captured from the
  live server.
- Added `test_remove_students.sh` and `test_check_submissions.sh` to the
  offline self-test suite; `assignment-admin`'s "Offline self-tests" menu
  option now runs all four (it previously only knew about the original
  two, so these would have silently never run from the menu).

### 2026-08-12 — Pre-deployment hardening pass

A security review of the integration pass below, done before first
installation on a live server. Found no broken plumbing -- the invariants in
`INTEGRATION_FIX_SPEC.md` all held -- but found gaps that survive a correct
implementation: no aggregate storage limit, backups that are corruption-
evident but not tamper-evident, generated passwords with no forced
expiration, and two TOCTOU/archive-extraction hardening gaps. All fixed
below; see each module's inline comments for the reasoning.

- **No aggregate submission quota.** `MAX_SUBMISSION_BYTES`/
  `MAX_SUBMISSION_FILES` bound a single `submit` call, but `ASSIGNMENT` is
  arbitrary student-chosen text and versions are never deleted, so nothing
  stopped one student from submitting under unlimited distinct assignment
  names, or resubmitting indefinitely, and filling the filesystem hosting
  `SUBMISSION_ROOT`. `asms-store` now enforces `MAX_STUDENT_ARCHIVE_BYTES`
  (a hard per-student total) and `SUBMISSION_MIN_FREE_BYTES` (a filesystem
  free-space floor) before accepting any submission. `verify_server.sh`
  reports current headroom against both. Put `SUBMISSION_ROOT` on its own
  filesystem with OS-level quotas for a real cohort; these are a backstop,
  not a substitute.
- **Backup integrity was corruption-evident only, not tamper-evident.**
  `MANIFEST.sha256` and the `.sha256` sidecar are both generated by the
  process that writes the archive, and live next to it -- proving nothing
  was corrupted, not that nothing was substituted by anyone who can write to
  `BACKUP_ROOT` or intercept an off-site copy. Since restoring a backup
  reinstalls the ASMS code itself and runs it as root, that mattered.
  `backup_system.sh` now GPG-signs the checksum sidecar when
  `BACKUP_GPG_KEY_ID` is configured; `restore_backup.sh` verifies the
  signature and refuses (with confirmation override) an unsigned archive
  when signing is configured, or an archive whose signature does not
  verify. Signing is off by default and both tools say so explicitly when
  it is, rather than silently.
- **Generated passwords never expired.** Provisioning told administrators to
  have students and faculty change their password at first login but never
  enforced it. `provision_students.sh` and `provision_faculty.sh` now call
  `chage -d 0` on every newly created account.
- **Home directories were briefly world-readable during provisioning.**
  `useradd --create-home` creates the directory at the distro default mode
  before it is `chmod 0700`'d afterward. Students share the `students`
  group on this host, so that gap -- however brief -- was a real window.
  The `useradd` call is now wrapped in a subshell with `umask 077`.
- **Symlink TOCTOU in `asms-store`.** The pre-copy symlink scan and `cp -a`
  were two separate steps, and the source lives inside the student's own
  writable `~/assignments` the whole time. `asms-store` now re-scans the
  reserved archive directory for symlinks immediately after the copy,
  before granting ACLs or writing the receipt, and rejects (with full
  cleanup) if any slipped through.
- **`restore_backup.sh` didn't reject symlink-typed tar entries.**
  Extraction refused absolute paths and `../` but not a symlink member,
  which could steer extraction of later archive members outside the work
  directory. Archives with any symlink-typed entry are now refused outright.
- **`submit` was compiled without `-Werror`**, contradicting the build
  command documented in `asms-submit.c`'s own header. `install.sh` now
  builds with `-Werror` first and only falls back to a plain build -- loudly
  -- if that fails, so a compiler warning on a setuid-root binary gets a
  human's attention instead of shipping silently.
- **`remove_student_account` skipped format validation.** It checked
  `is_protected_account`/`user_exists`/`is_student_user` but never
  `validate_username`, unlike the rest of the codebase's validate-then-act
  pattern. `utils.sh` now exposes `is_valid_username_format()` (the format
  half of `validate_username`, split out so the specific
  `REFUSED_PROTECTED` logging is preserved), and `remove_students.sh` calls
  it.
- **`is_demo_account` hardcoded the `demo` prefix** while
  `provision_students.sh --demo PREFIX COUNT` accepts any prefix, so
  "Remove demo/test accounts" silently found nothing for a differently
  prefixed batch. The pattern is now `DEMO_ACCOUNT_PATTERN` in
  `config.conf`.

Integration and correctness pass over the v2.0.0 scaffold, per
`INTEGRATION_FIX_SPEC.md`. The scaffold's modules were generated
independently and were not mutually consistent; this pass makes one canonical
implementation per responsibility.

### Added

- `install.sh` — the scaffold had no deployment path at all. Every module
  sourced `/opt/assignment-server/modules/utils.sh`, but nothing put files
  there, so no module could run. Idempotent; upgrades without destroying
  configuration, credentials, logs, backups, or submissions.
- `data/config.conf` — the canonical configuration every module already
  expected via `load_config` but which did not exist. Defines groups, paths,
  permission modes, mount options, password policy, and audit commands.
- `VERSION`, `README.md`, `CHANGELOG.md` — expected by `backup_system.sh`
  and `assignment-admin`, previously absent.

### Fixed

- **Student enumeration returned nothing, everywhere.** Students are created
  with `students` as their *primary* group, and primary membership does not
  appear in the member field of `/etc/group`. All six enumeration sites read
  that field, so every one returned an empty list for every student the
  system creates: no audit rules were generated, no mounts verified, "Remove
  All Students" removed nothing, and semester reset removed nothing.
  Replaced with a single `get_student_users()` in `utils.sh` that matches on
  primary GID as well as supplementary membership.
- **Demo provisioning could not run.** A bare `username` on its own line in
  `provision_students.sh` was a command invocation, not an assignment; under
  `set -e` it aborted the script on the first iteration.
- **Faculty provisioning aborted on password generation.** It called the
  `utils.sh` generator, whose `tr </dev/urandom | head -c` pipeline takes
  SIGPIPE under `set -o pipefail`, failing the command substitution and
  killing the script under `set -e`.
- **Mounts did not survive reboot.** `provision_students.sh` defined
  `add_fstab_entry` and never called it, so provisioned mounts existed only
  until reboot. fstab entries are now written at provisioning time by
  `configure_mounts.sh`.
- **Backup integrity verification always failed.** `finalize_backup`
  regenerated `MANIFEST.sha256` after the file already existed; the shell
  truncated it before `find` ran, so the manifest recorded the hash of an
  empty file for itself and `sha256sum -c` could never pass. The manifest is
  now generated once and excludes itself.
- **Restore silently did nothing for compressed archives.** `tar` produced a
  top-level directory, but restore looked for components at the extraction
  root. Restore now detects the archive's top-level directory.
- Removed dead `COMPRESSED` branch in `backup_system.sh`, which was
  initialised to `0` and never assigned, leaving the `.tar.gz` path
  unreachable.

### Changed

- **One ownership model for the submission archive.** Three modules disagreed
  about `/srv/submissions`: provisioning made it `assignment-submit`-owned
  `0700` with ACLs, `configure_mounts.sh` chowned it to the student, and
  `reset_semester.sh` reset the parent to `root:root 0755`. Because
  `configure_mounts.sh` reapplied its version on every mount operation, it
  granted students write access to their own archives — breaking the
  invariant that a student cannot delete submitted work — and its `chmod 700`
  rewrote the ACL mask, silently voiding both student and faculty read
  access. The archive is now uniformly `root:root`, written only by the
  setuid `submit` helper, with ACLs applied after creation and never
  `chmod`ed afterwards.
- **`submit` implemented.** Previously absent entirely, though
  `verify_server.sh` checked for it and `generate_audit.sh` wrote rules for
  it. Implemented as a setuid-root C shim that identifies the caller with
  `getuid()`, scrubs the environment, and execs a root-only-writable store
  helper. It must be a binary: Linux ignores the setuid bit on scripts. The
  `assignment-submit` service account is not used.
- **`configure_mounts.sh` is the single mount authority.** Duplicate mount
  and fstab logic removed from `provision_students.sh`, along with a third
  unused implementation in `utils.sh`. One canonical option set:
  `bind,ro,nosuid,nodev,noexec`.
- Mounts are verified read-only after every operation and explicitly
  remounted when the kernel did not honour `ro` — util-linux before 2.37
  (Ubuntu 20.04) ignores `ro` on a single-step bind mount and mounts
  read-write.
- **Modules accept flags and no longer require a terminal.** Every module was
  a bare interactive menu reading stdin, which is why `reset_semester.sh`
  duplicated account-removal logic rather than calling `remove_students.sh` —
  it could not. `reset_semester.sh` had also called `configure_mounts.sh`
  with stdout redirected to `/dev/null`, where it blocked on an invisible
  menu prompt. Menus are now thin wrappers over a flag-driven API, and
  `reset_semester.sh` calls the shared removal path.
- **Audit rules generated per GID rather than per UID.** Students' primary
  group is `students`, so a GID match covers exactly the student population
  and excludes faculty, admin, and service accounts. The previous approach
  emitted ~20 rules per student, which would have reached 6,000 rules at 300
  students. Audit command paths now resolve via `PATH` rather than being
  hardcoded to `/usr/bin`.
- Single password generator, used by all provisioning modules; the scaffold
  had three implementations. `generate_password.sh` can now be sourced as a
  library without executing.
- Protected accounts moved to `config.conf`; they were hardcoded in
  `remove_students.sh` and `remove_faculty.sh`.
- `CREDENTIAL_DIR` is honoured from configuration. Six modules hardcoded it
  after `load_config`, so setting it in the configuration file had no effect.
- `acl` added to the development environment package list; provisioning
  depends on `setfacl`, which nothing installed. `verify_server.sh` now
  checks for `setfacl`/`getfacl`.
- `assignment-admin` exposes `configure_mounts.sh` and `generate_audit.sh`,
  which were unreachable from the menu.

### Removed

- Unused mount, rollback, and logging helpers from `utils.sh` — a fourth
  mount implementation and a second logger competing with `logger.sh`.
- Dead `escaped_source`/`escaped_target` computation in `remove_students.sh`.

### Security

- The submission archive is never writable by a student, through the
  read-only view or directly.
- `/srv/submissions` is `0711`: traverse-only, so students cannot enumerate
  other students' accounts through it.
- Per-student archives are `root:root 0750` with an ACL naming exactly one
  student; group membership grants nothing.
- Generated passwords are never written to audit or administrative logs.
- Credential files are `root:root 0600` in a `root:root 0700` directory.
- Restore never writes `/etc/passwd`, `/etc/shadow`, or arbitrary archive
  paths into `/`; `/etc/fstab` is edited surgically.

---

## [2.0.0] — 2026-08-11

Initial scaffold. Modules were generated independently and are not
production-ready; see the Unreleased section above and
`INTEGRATION_FIX_SPEC.md`.
