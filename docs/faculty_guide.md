# ASMS Faculty Guide

Version 2.0.0 · For faculty reviewing student submissions

This guide covers everything you need to access and verify student
submissions on the assignment server. You can read submissions in a web
browser (next section) or through the terminal (SSH, sections 1–8). Either
way access is read-only by design: you can read anything a student has
submitted, but you cannot modify or delete it.

## Prefer a browser? Use the submissions page

Open this address in any browser, using the server's name or address:

```
https://<server-address>:8443/
```

Sign in with the **same username and password** you use for the server.

1. **Choose an assignment** and press **Open**.
2. **Choose a student** and press **View submission**. The list shows how
   many times each student submitted and when they last did.
3. You see every attempt the student made (the latest is shown first), a
   list of their files, and below it the full text of each file. Use
   **Download** to open PDFs and other files on your own computer.

Good to know:

- **The first visit shows a security warning.** The server uses its own
  certificate. If your administrator has told you to, choose *Advanced* and
  then *Proceed* / *Accept the risk*. You only need to do this once per
  browser.
- **New account?** Log in with SSH once first (section 1) to set your own
  password. The page will remind you if you haven't.
- **Five wrong passwords** lock the page for that username for five minutes.
- Press **Sign out** (top right) when you're done on a shared computer.

Every terminal example below is **real output**, captured from the actual
server (student account `demo01`, faculty account `pta1`). Your own
username and the students' usernames will differ — everything else will
look exactly like this.

> **Adding screenshots:** wherever you see a screenshot placeholder below,
> take the screenshot from your own terminal running the same command, save
> it into `docs/screenshots/` using the suggested filename, and it will
> appear in place of the placeholder in any Markdown viewer.

---

## 1. Logging in

```
ssh <your-username>@<server-address>
```

**First login:** you'll be forced to change your password immediately.

**If you were just added as faculty:** Linux reads your group membership
once, at login. If you were already logged in when an administrator added
you to the faculty group, your *existing* session won't see the new access
— **log out and log back in** before trying to read anything. This is the
single most common cause of an unexpected "Permission denied" for a newly
added faculty account.

> **📷 Screenshot placeholder** — *Capture your terminal at the SSH login /
> password-change prompt.*
>
> ![SSH login and forced password change](screenshots/faculty-01-login.png)

---

## 2. Where submissions live

Every student's submitted work is stored at:

```
/srv/submissions/<student-username>/<assignment-name>/<submission-NNN>/
```

For example:

```
/srv/submissions/bt25cse001/assignment01/submission-002/
```

Each version (`submission-001`, `submission-002`, ...) is a separate,
permanent, complete copy — nothing is ever overwritten. If a student
resubmitted five times, all five versions are still there for you to
compare.

---

## 3. Accessing a student's submission

You need to already know the student's username (from the class roster) —
**you cannot browse the submissions directory to see who exists.** This is
intentional, not a bug:

```
$ ls /srv/submissions
ls: cannot open directory '/srv/submissions': Permission denied
```

That's expected and correct — it's the exact same protection that keeps one
student from discovering another's username, and it applies to everyone,
faculty included. Instead, go straight to the student you already know:

```
$ ls -la /srv/submissions/demo01/assignment01/submission-001/
total 44
drwxr-x---+ 3 root root  4096 Aug 19 09:33 .
drwxr-x---+ 4 root root  4096 Aug 19 09:33 ..
-rw-r-x---+ 1 root root 15960 Aug 19 09:33 hello
-rw-r-x---+ 1 root root    83 Aug 19 09:33 hello.c
drwxr-x---+ 2 root root  4096 Aug 19 09:33 metadata

$ cat /srv/submissions/demo01/assignment01/submission-001/hello.c
#include <stdio.h>

int main(void) {
    printf("Hello, ASMS!\n");
    return 0;
}
```

> **📷 Screenshot placeholder** — *Capture the two commands above: the
> denied bare `ls`, then a successful `ls`/`cat` of one specific student's
> submission.*
>
> ![Denied bare ls, then successful access to a known student](screenshots/faculty-02-access.png)

---

## 4. Checking who has submitted, across the whole class

You don't have to check students one at a time. `assignment-check` reports
every student's status for one assignment in a single command — no root
needed, it uses the same ACL-granted read access you already have.

```
$ assignment-check assignment01
STUDENT            STATUS         VERSIONS   LATEST
-------            ------         --------   ------
bt25cse001         NOT submitted  -          -
bt25cse002         NOT submitted  -          -
bt25cse003         NOT submitted  -          -
bt25cse004         NOT submitted  -          -
bt25cse005         NOT submitted  -          -
bt25cse006         NOT submitted  -          -
bt25cse007         submitted      1          submission-001
...
bt25cse132         NOT submitted  -          -

Submitted: 4 / 123
```

*(output truncated here — the real command lists every student in the
class, not just the first few)*

Not sure what students actually named their assignment? List every distinct
assignment name seen across the whole class:

```
$ assignment-check --list-assignments
assignment01
```

> **📷 Screenshot placeholder** — *Capture `assignment-check ASSIGNMENT`
> and `assignment-check --list-assignments` in your own terminal.*
>
> ![assignment-check output](screenshots/faculty-05-assignment-check.png)

**Only faculty (and root) can run this.** A student attempting it is
refused immediately:

```
$ assignment-check assignment01
assignment-check: you must be a member of 'faculty' to run this.
```

This is a convenience layered on top of the same permissions you already
have — it doesn't grant you anything new, it just automates checking every
student instead of one at a time by hand.

---

## 5. Verifying a submission hasn't been tampered with

Every submission includes a SHA-256 manifest of every file in it:

```
$ cd /srv/submissions/demo01/assignment01/submission-001/
$ sha256sum -c metadata/MANIFEST.sha256
./hello: OK
./hello.c: OK
```

If a file's content had changed since submission, this would report `FAILED`
instead of `OK`. Useful if a grading dispute ever comes up and you want
cryptographic proof the file is exactly what was submitted.

The receipt (`metadata/receipt.txt`) alongside it records the student,
assignment, version, exact submission timestamp, file count, and size.

> **📷 Screenshot placeholder** — *Capture `sha256sum -c` succeeding, as
> shown above.*
>
> ![sha256sum -c verifying a submission manifest](screenshots/faculty-03-verify.png)

---

## 6. What you cannot do (and why)

```
$ echo graded >> /srv/submissions/demo01/assignment01/submission-001/hello.c
bash: line 1: .../hello.c: Permission denied
```

Your access is **read-only**, enforced by the filesystem itself, not by
policy. Faculty can read every student's work but cannot modify or delete
any of it — this protects the integrity of the submission record for
everyone, including you: nobody can later claim a submission was altered
after the fact by anyone, faculty included.

If you want to annotate or grade a copy, copy the file out to your own home
directory first (`cp` it somewhere under your own account) and work on the
copy — the original submission is untouched either way.

> **📷 Screenshot placeholder** — *Capture an attempted edit being refused,
> as shown above.*
>
> ![Attempted edit refused](screenshots/faculty-04-readonly.png)

---

## 7. Common errors

| You typed | What happened | Why |
|---|---|---|
| `ls /srv/submissions` | `Permission denied` | Expected — the directory is traverse-only, not listable, for anyone. Go straight to a known student's folder instead. |
| Any access right after being added to faculty group | `Permission denied` on things that should work | You need to log out and log back in — see §1. |
| Editing/deleting a submitted file | `Permission denied` / `Read-only file system` | By design — faculty access is read-only. Copy the file elsewhere if you need to work on it. |
| `cd /srv/submissions/<username>` for a student who hasn't submitted anything yet | `No such file or directory` | The per-assignment folder is only created on first submission — nothing to see until they submit. |
| `assignment-check ASSIGNMENT` as a student | `you must be a member of 'faculty' to run this.` | Correct — it's a faculty-only tool. |

---

## 8. FAQ

**How do I know which students have submitted an assignment, across the
whole class?**
Use `assignment-check ASSIGNMENT` — see §4. It lists every student's status
in one command; you don't need to check the roster by hand.

**Can I grade/comment directly on a submission?**
Not in place — submissions are read-only for everyone, including faculty,
by design. Copy the file to your own space first if you want to annotate it.

**A student says they submitted but I don't see it — what do I check?**
Run `assignment-check ASSIGNMENT` first — if it shows them as "NOT
submitted", either they used a different assignment name than you expected
(check `assignment-check --list-assignments` for what names actually exist)
or they haven't actually run `submit` yet — compiling and testing locally
doesn't submit anything by itself. If it shows them as submitted, ask for
their exact receipt output (or version number, e.g. `submission-003`) and
check that specific path directly.

**I still get "Permission denied" after logging out and back in.**
That's not the normal cause — ask your administrator to check your account
is actually in the `faculty` group (`id <your-username>` should list
`faculty`) and that the specific student's archive has the expected
permissions.

---

*Questions not covered here? Ask your course administrator.*
