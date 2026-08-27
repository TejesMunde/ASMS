/*
 * Assignment Server Management System (ASMS)
 * submit -- student submission command
 * Version: 2.0.0
 *
 * A setuid-root shim. Its only job is to establish WHO is submitting and to
 * refuse anything that is not a well-formed submission, then hand off to the
 * store helper with a clean environment.
 *
 * Why this is a compiled binary and not a shell script:
 *
 *   Linux ignores the setuid bit on interpreted files. A setuid shell script
 *   silently runs with the caller's privileges, so it could never write to a
 *   root-owned archive. There is no way to make the script version work.
 *
 * The security properties this file is responsible for:
 *
 *   1. Identity comes from getuid(). Not argv, not $USER, not $LOGNAME, not
 *      anything the caller controls. A student cannot submit as another
 *      student.
 *   2. The source path is resolved with realpath() and must lie inside the
 *      caller's own assignments directory, so symlink and ../ tricks cannot
 *      pull files in from elsewhere on the system.
 *   3. The environment is erased before exec, so the helper cannot be
 *      steered through PATH, IFS, BASH_ENV, LD_PRELOAD or similar.
 *   4. Real, effective and saved UIDs are all set to 0 before exec. bash
 *      drops privileges when euid != uid unless invoked with -p, so a shell
 *      helper would otherwise run unprivileged and fail.
 *   5. The helper is verified to be root-owned and not group- or
 *      world-writable. Anyone able to write it would gain root through this
 *      binary.
 *
 * Build (install.sh does this):
 *   gcc -O2 -Wall -Wextra -Werror \
 *       -DASMS_STORE_HELPER='"/usr/local/libexec/asms-store"' \
 *       -DASMS_STUDENT_GROUP='"students"' \
 *       -o submit asms-submit.c
 */

#define _GNU_SOURCE

#include <errno.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef ASMS_STORE_HELPER
#define ASMS_STORE_HELPER "/usr/local/libexec/asms-store"
#endif

#ifndef ASMS_STUDENT_GROUP
#define ASMS_STUDENT_GROUP "students"
#endif

#define MAX_ASSIGNMENT_LEN 64
#define MAX_GROUPS 128

static void fail(const char *message)
{
    fprintf(stderr, "submit: %s\n", message);
    exit(1);
}

static void fail_errno(const char *message)
{
    fprintf(stderr, "submit: %s: %s\n", message, strerror(errno));
    exit(1);
}

static void usage(void)
{
    fputs(
        "Usage:\n"
        "  submit ASSIGNMENT              Submit ~/assignments/ASSIGNMENT\n"
        "  submit ASSIGNMENT PATH         Submit PATH (must be inside ~/assignments)\n"
        "\n"
        "Your work is copied into the server's submission archive. Each\n"
        "submission is kept as a new numbered version; nothing you submitted\n"
        "earlier is ever overwritten.\n"
        "\n"
        "View your submissions under ~/submissions (read-only).\n",
        stdout);
}

/*
 * Assignment names become directory names inside the archive, so they are
 * restricted to a conservative character set. This is enforced again in the
 * store helper: the shim is not the only line of defence.
 */
static int valid_assignment(const char *name)
{
    size_t length = strlen(name);

    if (length == 0 || length > MAX_ASSIGNMENT_LEN)
        return 0;

    /* Must not start with a dot, so "." and hidden names are excluded. */
    if (!((name[0] >= 'A' && name[0] <= 'Z') ||
          (name[0] >= 'a' && name[0] <= 'z') ||
          (name[0] >= '0' && name[0] <= '9')))
        return 0;

    for (size_t i = 0; i < length; i++) {
        char c = name[i];

        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
            continue;

        return 0;
    }

    if (strstr(name, "..") != NULL)
        return 0;

    return 1;
}

static int in_student_group(const struct passwd *pw)
{
    struct group *gr = getgrnam(ASMS_STUDENT_GROUP);

    if (gr == NULL)
        return 0;

    /* Students have the students group as their PRIMARY group. */
    if (pw->pw_gid == gr->gr_gid)
        return 1;

    /* Supplementary membership is equally valid. */
    gid_t groups[MAX_GROUPS];
    int ngroups = MAX_GROUPS;

    /*
     * Returns -1 when the caller belongs to more groups than fit, having
     * filled the array and set ngroups to the number required. The entries
     * that did fit are still valid, so scan those.
     */
    if (getgrouplist(pw->pw_name, pw->pw_gid, groups, &ngroups) < 0)
        ngroups = MAX_GROUPS;

    for (int i = 0; i < ngroups && i < MAX_GROUPS; i++) {
        if (groups[i] == gr->gr_gid)
            return 1;
    }

    return 0;
}

/*
 * True when "path" is "prefix" itself or lies beneath it.
 *
 * The boundary check matters: a plain strncmp would accept
 * "/home/alice/assignments-scratch" as being inside "/home/alice/assignments".
 * Both arguments are already realpath()-resolved by the caller.
 */
static int path_is_within(const char *path, const char *prefix)
{
    size_t prefix_length = strlen(prefix);

    if (strncmp(path, prefix, prefix_length) != 0)
        return 0;

    if (path[prefix_length] == '\0')
        return 1;

    return path[prefix_length] == '/';
}

static void verify_helper_is_safe(void)
{
    struct stat st;

    if (stat(ASMS_STORE_HELPER, &st) != 0)
        fail_errno("submission helper is not installed (" ASMS_STORE_HELPER ")");

    if (!S_ISREG(st.st_mode))
        fail("submission helper is not a regular file");

    if (st.st_uid != 0)
        fail("submission helper is not owned by root; refusing to run");

    /*
     * A group- or world-writable helper is a root escalation through this
     * setuid binary, so this is fatal rather than a warning.
     */
    if (st.st_mode & (S_IWGRP | S_IWOTH))
        fail("submission helper is writable by non-root; refusing to run");
}

int main(int argc, char **argv)
{
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 ||
                      strcmp(argv[1], "--help") == 0)) {
        usage();
        return 0;
    }

    if (argc < 2 || argc > 3) {
        usage();
        return 2;
    }

    const char *assignment = argv[1];

    if (!valid_assignment(assignment))
        fail("invalid assignment name (use letters, digits, dot, underscore, hyphen)");

    /*
     * Identity is taken from the real UID. Everything the caller could
     * influence -- arguments, environment, the terminal -- is irrelevant
     * here, which is what stops one student submitting as another.
     */
    uid_t caller_uid = getuid();
    struct passwd *pw = getpwuid(caller_uid);

    if (pw == NULL)
        fail("cannot determine your account");

    if (caller_uid == 0)
        fail("root cannot submit; run this as the student account");

    if (!in_student_group(pw))
        fail("your account is not a student account");

    /* Copy the fields needed after the environment is cleared. */
    char username[LOGIN_NAME_MAX + 1];
    char home[PATH_MAX];

    if (snprintf(username, sizeof(username), "%s", pw->pw_name) < 0 ||
        strlen(pw->pw_name) >= sizeof(username))
        fail("account name is too long");

    if (snprintf(home, sizeof(home), "%s", pw->pw_dir) < 0 ||
        strlen(pw->pw_dir) >= sizeof(home))
        fail("home directory path is too long");

    /* The only area a submission may be taken from. */
    char assignments_dir[PATH_MAX];
    int written = snprintf(assignments_dir, sizeof(assignments_dir),
                           "%s/assignments", home);

    if (written < 0 || (size_t)written >= sizeof(assignments_dir))
        fail("assignments directory path is too long");

    char resolved_assignments[PATH_MAX];

    if (realpath(assignments_dir, resolved_assignments) == NULL)
        fail_errno("cannot access your assignments directory");

    /* Default source: the assignment's own directory. */
    char requested[PATH_MAX];

    if (argc == 3) {
        if (snprintf(requested, sizeof(requested), "%s", argv[2]) < 0 ||
            strlen(argv[2]) >= sizeof(requested))
            fail("source path is too long");
    } else {
        written = snprintf(requested, sizeof(requested), "%s/%s",
                           resolved_assignments, assignment);

        if (written < 0 || (size_t)written >= sizeof(requested))
            fail("source path is too long");
    }

    /*
     * realpath() resolves every symlink and ".." component, so the check
     * below is against the true location on disk rather than the text the
     * caller supplied.
     */
    char resolved_source[PATH_MAX];

    if (realpath(requested, resolved_source) == NULL) {
        if (argc == 2)
            fprintf(stderr,
                    "submit: no such assignment: %s\n"
                    "submit: expected it at %s/%s\n",
                    assignment, resolved_assignments, assignment);
        else
            fprintf(stderr, "submit: cannot access %s: %s\n",
                    requested, strerror(errno));

        return 1;
    }

    if (!path_is_within(resolved_source, resolved_assignments)) {
        fprintf(stderr,
                "submit: you can only submit work from %s\n",
                resolved_assignments);
        return 1;
    }

    /* Submitting the whole assignments directory is almost never intended. */
    if (strcmp(resolved_source, resolved_assignments) == 0)
        fail("refusing to submit your entire assignments directory; "
             "name the assignment's own directory or file");

    struct stat source_stat;

    if (lstat(resolved_source, &source_stat) != 0)
        fail_errno("cannot inspect the source path");

    if (!S_ISDIR(source_stat.st_mode) && !S_ISREG(source_stat.st_mode))
        fail("only a directory or a regular file can be submitted");

    verify_helper_is_safe();

    /*
     * Do not hold a working directory the caller controls: it could be
     * unmounted or replaced while the helper runs.
     */
    if (chdir("/") != 0)
        fail_errno("cannot change to a safe working directory");

    /*
     * Become fully root before exec.
     *
     * The setuid bit gives euid 0 but leaves ruid as the student. bash resets
     * euid back to ruid on startup unless given -p, so the helper would run
     * unprivileged and fail to write the archive. Setting all three UIDs
     * avoids that and also means the helper cannot accidentally regain the
     * student's identity.
     *
     * Supplementary groups are dropped first, while still privileged.
     */
    if (setgroups(0, NULL) != 0)
        fail_errno("cannot drop supplementary groups");

    if (setresgid(0, 0, 0) != 0)
        fail_errno("cannot set group identity");

    if (setresuid(0, 0, 0) != 0)
        fail_errno("cannot acquire the privileges needed to write the archive");

    /*
     * Erase the environment. The helper is a shell script, so PATH, IFS,
     * BASH_ENV, ENV and SHELLOPTS would all be levers if they survived.
     */
    if (clearenv() != 0)
        fail("cannot clear the environment");

    if (setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1) != 0 ||
        setenv("IFS", " \t\n", 1) != 0 ||
        setenv("LC_ALL", "C", 1) != 0)
        fail("cannot establish a clean environment");

    /*
     * The username is passed as an argument because it was derived from
     * getuid() here; the helper never has to guess who is calling.
     */
    execl(ASMS_STORE_HELPER, "asms-store",
          username, assignment, resolved_source, (char *)NULL);

    fail_errno("cannot start the submission helper");
    return 1;
}
