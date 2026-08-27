# ASMS v2.0 — Integration Repair Specification

## Purpose

This document is the authoritative handoff specification for fixing and integrating the current
Assignment Server Management System (ASMS) scaffold.

The current scaffold contains the modules listed below, but they were generated independently.
They must NOT be treated as production-ready.

The next phase is an **integration and correctness pass**, not the addition of unrelated features.

The final objective is a working Ubuntu/Debian-based university assignment server where:

- Students have isolated Linux accounts.
- Faculty have separate Linux accounts.
- Each student has a writable assignment/work area.
- Each student has a read-only view of only their own submitted work.
- A student's submissions are stored in an authoritative server-side archive.
- Student A cannot access Student B's submissions.
- Faculty can access the submissions they are supposed to review.
- The `submit` command copies/submits work into the authoritative archive.
- The submission view available to students is read-only.
- Student command execution can be audited with auditd.
- Student provisioning and faculty provisioning are repeatable.
- Mounts survive reboot.
- Backups and restores are safe.
- Semester reset is controlled and recoverable.
- The administration interface exposes the whole system.
- The final system has one canonical implementation for each responsibility.

---

# 1. Current Scaffold

The current package contains:

1. `utils.sh`
2. `logger.sh`
3. `assignment-admin`
4. `provision_students.sh`
5. `provision_faculty.sh`
6. `remove_students.sh`
7. `remove_faculty.sh`
8. `install_devtools.sh`
9. `verify_server.sh`
10. `generate_audit.sh`
11. `configure_mounts.sh`
12. `generate_password.sh`
13. `backup_system.sh`
14. `restore_backup.sh`
15. `reset_semester.sh`

The scaffold is a starting point only.

---

# 2. Most Important Final Architecture

## 2.1 Student account

A student account should have a structure conceptually like:

```text
/home/<student>/
├── assignments/
└── submissions/
```

### `assignments/`

This is the student's normal working/submission source area.

The student must be able to:

- create files
- edit files
- compile programs
- run programs
- organize assignment work

### `submissions/`

This is NOT the authoritative storage.

It is a **read-only bind-mounted view** of that student's authoritative submission archive.

A student must be able to inspect what they submitted, but must not be able to modify or delete it through this directory.

---

# 3. Authoritative Submission Architecture

The authoritative storage should be:

```text
/srv/submissions/
└── <student>/
    └── <assignment>/
        └── <submission-version>/
            ├── submitted files...
            └── metadata/receipt as designed
```

The exact final submission-version naming can be chosen during integration, but it must be deterministic,
safe, and documented.

For example:

```text
/srv/submissions/bt25cse001/assignment01/submission-001/
```

The student's view should correspond only to:

```text
/home/bt25cse001/submissions/assignment01/submission-001/
```

or an equivalent bind-mounted structure.

## Critical isolation rule

Student A:

```text
/home/studentA/submissions
```

must resolve only to:

```text
/srv/submissions/studentA
```

Student A must NEVER receive a mount or permission allowing access to:

```text
/srv/submissions/studentB
```

---

# 4. Submit Command Architecture

The final `submit` command must:

1. Validate the caller.
2. Identify the current student from the authenticated Linux account.
3. Validate the assignment identifier.
4. Validate the source path.
5. Reject paths outside the student's permitted working area.
6. Create the authoritative submission directory.
7. Copy the submission atomically.
8. Preserve the intended file structure.
9. Create submission metadata/receipt where appropriate.
10. Set correct ownership and permissions.
11. Log the submission.
12. Never allow a student to overwrite another student's archive.
13. Never require writing to the student's read-only `~/submissions` mount.

### Critical correction

The submission command must write to:

```text
/srv/submissions/<student>/...
```

not to:

```text
/home/<student>/submissions/...
```

because `~/submissions` is intentionally read-only.

The read-only mount is only the student's viewing mechanism.

---

# 5. Current Integration Problems

## CRITICAL 1 — Missing configuration file

Most modules execute:

```bash
load_config
```

and expect:

```text
/opt/assignment-server/data/config.conf
```

The current scaffold does not include the configuration file.

### Required fix

Create a canonical configuration file and define all shared variables in one place.

At minimum it must define/document:

```text
ASMS_ROOT
STUDENT_GROUP
FACULTY_GROUP
SUBMISSION_ROOT
BACKUP_ROOT
SEMESTER_ARCHIVE_ROOT
CREDENTIAL_DIR
DEFAULT_SHELL
PASSWORD_LENGTH
```

Do not duplicate conflicting defaults throughout modules.

---

# 6. CRITICAL 2 — Student discovery is inconsistent

Some modules discover students using:

```bash
getent group students
```

while provisioning may create a student with `students` as the primary group.

A user whose primary group is `students` may not reliably appear in the supplementary-member field of the group entry.

### Required fix

Create one canonical function, for example:

```bash
get_student_users()
```

or equivalent.

It must identify all current student accounts reliably, including users whose primary group is `students`.

All of these modules must use the same function:

```text
provision_students.sh
remove_students.sh
generate_audit.sh
configure_mounts.sh
verify_server.sh
reset_semester.sh
```

No module should implement its own student-discovery logic.

---

# 7. CRITICAL 3 — Mount implementation is duplicated

`provision_students.sh` currently contains its own mount and fstab logic.

A separate module also exists:

```text
configure_mounts.sh
```

This creates two implementations.

The two implementations currently use different mount options.

### Required architecture

`configure_mounts.sh` must become the single authority for:

- creating the archive
- creating the mount point
- bind mounting
- read-only remount
- fstab entry creation
- fstab entry removal
- mount verification
- unmounting
- bulk mount configuration

`provision_students.sh` should call that module or a shared function exported by a common library.

It must NOT duplicate mount implementation.

---

# 8. CRITICAL 4 — Mount options are inconsistent

One implementation currently creates a basic bind mount.

Another uses:

```text
bind,ro,nosuid,nodev,noexec
```

### Required decision

The final architecture must define one canonical set of mount options.

At minimum the student-facing submission mount must be:

```text
read-only
```

Additional hardening such as:

```text
nosuid
nodev
noexec
```

should be retained only if it is compatible with the intended submission behavior.

The authoritative archive and student-facing mount have different purposes and must not be confused.

---

# 9. CRITICAL 5 — Submission archive ownership is inconsistent

The submit workflow needs write access to the authoritative archive.

The student-facing mount must be read-only.

Do NOT solve this by making the student's read-only mount writable.

The final design must establish the exact identity that performs the authoritative write.

Possible designs include:

- controlled privileged `submit` helper
- dedicated service account plus carefully restricted ACL
- root-owned submission archive with a tightly scoped privileged helper

The final implementation must choose one model and document it.

Do not use broad `777` permissions.

---

# 10. CRITICAL 6 — `submit` is not fully integrated

The verification module expects:

```text
/usr/local/bin/submit
```

but the current scaffold does not provide a complete installation/deployment path for it.

There are also incompatible submission layouts in the current scripts.

### Required fix

There must be one final submit implementation and one final installation path.

The final submit command must be installed to:

```text
/usr/local/bin/submit
```

and verified by `verify_server.sh`.

---

# 11. CRITICAL 7 — Submit path conflicts with read-only mount

A previous submit implementation attempted to create/write a receipt through:

```text
~/submissions
```

This contradicts the final architecture.

### Required rule

Students submit FROM their writable assignment/work area.

The server stores the authoritative copy.

The student later sees that copy through the read-only mount.

Never write the authoritative submission through the read-only view.

---

# 12. HIGH — `assignment-submit` service account is undefined

Some student provisioning logic assumes a dedicated account/service identity such as:

```text
assignment-submit
```

but there is no canonical provisioning module for it.

### Required fix

Choose one final submission-write model.

If `assignment-submit` is retained:

- provision it explicitly
- give it only the permissions it needs
- never give students its credentials
- document ownership/ACL behavior
- verify it during server verification

---

# 13. HIGH — ACL dependency is missing

Student provisioning uses ACL functionality such as:

```bash
setfacl
```

but the development-tool installation list does not necessarily install the `acl` package.

### Required fix

Add the required package to the server dependency installation.

Also verify:

```bash
command -v setfacl
command -v getfacl
```

during server verification.

---

# 14. HIGH — Password generation is duplicated

There is password-generation logic in:

```text
utils.sh
```

and a dedicated:

```text
generate_password.sh
```

### Required fix

Choose one canonical implementation.

Recommended:

```text
generate_password.sh
```

or a shared library function used by all provisioning modules.

Do not maintain two implementations.

The final implementation must avoid `pipefail`/SIGPIPE problems and must not log generated passwords.

---

# 15. HIGH — Backup manifest design needs correction

The backup module generates SHA-256 manifests while also creating the manifest inside the backup.

This can result in the manifest attempting to include itself or being generated before final archive changes.

### Required fix

Use a clear scheme:

```text
backup/
├── data...
└── MANIFEST.sha256
```

where the manifest contains hashes of the data files but NOT itself.

For compressed archives, generate the manifest against the extracted content before compression, or define a separate archive checksum.

The restore process must use the same scheme.

---

# 16. HIGH — Backup/restore format is inconsistent

`backup_system.sh` has partial compression logic, while `restore_backup.sh` expects a particular directory layout.

### Required fix

Choose one canonical backup format.

Recommended:

```text
/opt/assignment-server/backups/
└── full-YYYY-MM-DD_HH-MM-SS_hostname.tar.gz
```

with:

```text
manifest
backup metadata
configuration
credentials
submissions
logs
```

inside the archive.

Restore must correctly detect the archive's top-level directory and restore from it.

---

# 17. HIGH — Backup restore must never blindly overwrite system files

Restore should only modify explicitly approved ASMS-owned resources.

Never restore arbitrary paths from a backup archive into `/`.

Never restore:

```text
/etc/shadow
/etc/passwd
```

as raw files.

ASMS configuration should be restored selectively.

---

# 18. HIGH — Semester reset duplicates removal logic

`reset_semester.sh` directly removes student accounts rather than using the student-removal module.

### Required fix

Prefer a shared library/helper for:

```text
student enumeration
mount removal
account removal
credential cleanup
archive handling
```

Then both:

```text
remove_students.sh
reset_semester.sh
```

call the same implementation.

Do not duplicate destructive account-removal logic.

---

# 19. MEDIUM — Admin interface needs final integration

`assignment-admin` has now been updated to expose the current modules.

However, it must be re-tested after the shared architecture is corrected.

Every menu option must point to a real executable module with a consistent exit-code contract.

---

# 20. MEDIUM — Missing project metadata

The backup module expects files such as:

```text
VERSION
README.md
CHANGELOG.md
```

These need to be created as part of the final project.

---

# 21. Security Requirements

The final system must satisfy these invariants.

## Student isolation

Student A cannot:

```text
read Student B submissions
write Student B submissions
delete Student B submissions
modify Student B metadata
mount Student B archive
```

## Student submission view

Student can:

```text
list own submissions
read own submitted files
```

Student cannot:

```text
modify own submitted files
delete own submitted files
replace submission metadata
```

## Faculty

Faculty access must be explicitly defined and implemented.

Do not assume that membership in `faculty` automatically grants filesystem access.

Use ACLs/groups/permissions deliberately.

## Credentials

Credential files must be:

```text
root:root
0600
```

and the credential directory:

```text
root:root
0700
```

Passwords must never be written to audit logs or ordinary ASMS logs.

---

# 22. Audit Requirements

Audit should track student execution of relevant commands.

Current target commands include:

```text
rm
cp
mv
chmod
chown
git
python3
sudo
su
submit
```

Rules should be generated for actual student accounts rather than relying on a hard-coded UID range.

The system should regenerate audit rules when student membership changes.

Audit rules must not accidentally cover faculty/admin/service accounts.

---

# 23. Required Final Testing

Before declaring ASMS production-ready, create at least:

```text
student A
student B
faculty account
```

Then test:

### Student A

- create assignment
- edit assignment
- submit
- view submission
- attempt to modify submission
- attempt to delete submission

### Student B

- create assignment
- submit
- verify own submission

### Cross-student isolation

Student A must NOT be able to:

```text
ls /home/studentB/submissions
cat /home/studentB/submissions/...
cat /srv/submissions/studentB/...
```

assuming those paths are outside A's authorized view.

### Faculty

Verify faculty can access the intended submission areas.

### Audit

Verify:

```bash
ausearch -k student_cmd_submit
ausearch -k student_cmd_cp
ausearch -k student_cmd_rm
```

or the final equivalent keys.

### Reboot

After provisioning:

```bash
reboot
```

and verify all expected student bind mounts return correctly.

### Backup

Test:

```text
create backup
delete/change data
restore backup
verify
```

### Semester reset

Test on demo accounts first:

```text
provision demo students
submit demo assignments
reset semester
verify old submissions archived
verify student accounts removed
verify mounts removed
verify audit rules regenerated
verify server
```

---

# 24. Recommended Integration Order

Do NOT fix modules randomly.

Use this order:

## Step 1 — Configuration

Create:

```text
data/config.conf
VERSION
README.md
CHANGELOG.md
```

## Step 2 — Shared utilities

Fix:

```text
utils.sh
logger.sh
generate_password.sh
```

Create canonical:

```text
get_student_users()
get_faculty_users()
```

and shared validation/path helpers.

## Step 3 — Mount architecture

Fix:

```text
configure_mounts.sh
provision_students.sh
verify_server.sh
```

Make `configure_mounts.sh` authoritative.

## Step 4 — Submission system

Implement/finalize:

```text
submit v2.1
```

and its installation/provisioning.

## Step 5 — Account management

Fix:

```text
provision_students.sh
provision_faculty.sh
remove_students.sh
remove_faculty.sh
```

## Step 6 — Audit

Fix:

```text
generate_audit.sh
```

using the canonical student enumeration.

## Step 7 — Backup

Fix:

```text
backup_system.sh
restore_backup.sh
```

and test them together.

## Step 8 — Semester lifecycle

Fix:

```text
reset_semester.sh
```

using shared functions.

## Step 9 — Verification

Fix:

```text
verify_server.sh
```

so every check reflects the final architecture.

## Step 10 — Admin

Re-test:

```text
assignment-admin
```

## Step 11 — Full integration test

Run the complete student A/B/faculty isolation and lifecycle tests.

---

# 25. Do Not Add New Features Yet

Do NOT add the following until the integration pass is complete:

- Git repository integration
- web dashboard
- automated email
- notifications
- grading system
- LMS integration
- Docker isolation
- containerized compilation
- additional monitoring
- unrelated automation

Those are future enhancements.

The immediate goal is a secure, correct, testable core ASMS.

---

# 26. Definition of Done

ASMS v2.0 is complete only when:

[ ] Clean installation works.

[ ] Configuration is centralized.

[ ] All modules source the same shared configuration.

[ ] Student enumeration is canonical.

[ ] Faculty enumeration is canonical.

[ ] Student provisioning works.

[ ] Faculty provisioning works.

[ ] Student removal works.

[ ] Faculty removal works.

[ ] Per-student bind mounts work.

[ ] Bind mounts survive reboot.

[ ] Student submission view is read-only.

[ ] Student A cannot access Student B's submissions.

[ ] Submit command works.

[ ] Submit writes only to the authoritative archive.

[ ] Faculty access works as designed.

[ ] Audit rules work.

[ ] Audit rules update after student changes.

[ ] Development tools install correctly.

[ ] Server verification passes.

[ ] Backup works.

[ ] Restore works.

[ ] Backup integrity verification works.

[ ] Semester reset works.

[ ] Semester reset archives old submissions.

[ ] Admin interface controls all modules.

[ ] No module contains conflicting duplicate implementations.

[ ] Shell scripts pass ShellCheck.

[ ] Full integration test passes.

---

# 27. Instruction to the Next AI

You are taking over an existing ASMS scaffold.

Do NOT assume the current code is correct merely because it exists.

First:

1. Inspect every file in this package.
2. Compare the implementations against this specification.
3. Identify inconsistencies.
4. Fix the architecture from the foundation upward.
5. Do not introduce unrelated features.
6. Preserve the final student-isolation architecture.
7. Keep one canonical implementation for each responsibility.
8. Test every integration point before moving forward.
9. Update documentation when behavior changes.
10. Do not declare the system production-ready until the Definition of Done is satisfied.

The most important invariant is:

> **Students can submit from their writable assignment area and later view exactly their own submitted copies through a read-only mount, while having no access to another student's submission area.**

This invariant must not be weakened to make implementation easier.
