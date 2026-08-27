# ASMS Student Guide

Version 2.0.0 · For students using the Assignment Server Management System

This guide walks through everything you need to do on the assignment server:
logging in, writing and compiling code, submitting your work, and checking
what you've submitted.

Every terminal example below is **real output**, captured from the actual
server using a test account (`demo01`). Your own username, timestamps, and
file sizes will differ — everything else will look exactly like this.

> **Adding screenshots:** wherever you see a screenshot placeholder below,
> take the screenshot from your own terminal (running the same command
> shown just above it), save it into `docs/screenshots/` using the suggested
> filename, and it will appear in place of the placeholder automatically in
> any Markdown viewer (GitHub, VS Code, etc.).

---

## 1. The mental model

You have two folders. Only one of them is yours to write to.

```
~/assignments/     your working area — create, edit, compile, run, delete
                    freely. This is where you do your work.

~/submissions/      a READ-ONLY window onto what you've submitted. You can
                    look at it, but you cannot change or delete anything
                    inside it — not even your own files. The server refuses
                    at the kernel level, not just by asking nicely.
```

The actual permanent copy of your submitted work lives on the server, out of
your reach entirely. `~/submissions` is just a view of it. This is
deliberate: once you submit something, it is a permanent, tamper-proof
record — for your protection as much as anyone else's. If a grading dispute
ever comes up, what's in the archive is provably exactly what you submitted,
when you submitted it.

> **📷 Screenshot placeholder** — *Capture: `ls -la ~` showing both
> `assignments` and `submissions` in your home directory.*
>
> ![ls -la ~ showing assignments and submissions directories](screenshots/student-01-directories.png)

---

## 2. Logging in

Connect over SSH with the username and password your instructor gave you:

```
ssh <your-username>@<server-address>
```

**First login:** you will be forced to change your password immediately —
this is not optional and not a bug. Pick something you'll remember; there's
no password-recovery flow here beyond asking an administrator to reset it.

> **📷 Screenshot placeholder** — *Capture your terminal at the SSH login
> prompt / forced password change.*
>
> ![SSH login and forced password change](screenshots/student-02-login.png)

---

## 3. Writing and compiling your work

Everything happens inside `~/assignments`. Make a subfolder per assignment —
this keeps your submissions organized and matches how `submit` expects to
find your work.

```
$ mkdir -p ~/assignments/assignment01
$ cd ~/assignments/assignment01
$ cat > hello.c << 'EOF'
#include <stdio.h>

int main(void) {
    printf("Hello, ASMS!\n");
    return 0;
}
EOF
$ gcc -o hello hello.c
$ ./hello
Hello, ASMS!
```

Use whatever tools you like in here — `vim`, `nano`, `git`, `python3`,
`gcc`, `g++`, `java`, `make` are all available. This directory is entirely
yours: create, edit, compile, run, reorganize, delete — none of it is
visible to other students, and none of it counts as "submitted" until you
explicitly run `submit`.

> **📷 Screenshot placeholder** — *Capture yourself editing/compiling in
> `~/assignments/assignment01`.*
>
> ![Editing and compiling inside ~/assignments](screenshots/student-03-editing.png)

---

## 4. Submitting your work

```
$ submit assignment01
```

That submits `~/assignments/assignment01` (an entire directory) under the
assignment name `assignment01`. Real output from the server:

```
[ OK ] Submitted assignment01 as submission-001

  Files   : 2
  Size    : 16043 bytes
  Receipt : /home/demo01/submissions/assignment01/submission-001/metadata/receipt.txt

[INFO] View your submission (read-only): /home/demo01/submissions/assignment01/submission-001
```

**Two ways to call it:**

```
submit ASSIGNMENT              submits ~/assignments/ASSIGNMENT (the whole folder)
submit ASSIGNMENT PATH         submits a specific file or folder inside ~/assignments
```

Every submission is versioned automatically (`submission-001`,
`submission-002`, ...) — resubmitting **never** overwrites or deletes an
earlier attempt. If you fix a bug and resubmit, both versions exist
permanently; the grader (or you) can always see exactly what changed and
when.

> **📷 Screenshot placeholder** — *Capture the output of a real `submit`
> command.*
>
> ![submit command output](screenshots/student-04-submit.png)

### What "submitted" actually means

Every submission gets a **receipt** recording exactly what happened:

```
$ cat ~/submissions/assignment01/submission-001/metadata/receipt.txt
ASMS Submission Receipt

Student     : demo01
Assignment  : assignment01
Version     : submission-001
Submitted   : 2026-08-19 09:33:15 IST
Host        : poweredge-t440

Files       : 2
Bytes       : 16043
Source      : /home/demo01/assignments/assignment01

Stored at   : /srv/submissions/demo01/assignment01/submission-001
Visible at  : /home/demo01/submissions/assignment01/submission-001

File hashes are in MANIFEST.sha256 in this directory. Verify with:
  cd /home/demo01/submissions/assignment01/submission-001
  sha256sum -c metadata/MANIFEST.sha256

This submission is stored on the server and cannot be modified or deleted
from your account.
```

The manifest (`MANIFEST.sha256`) is a cryptographic fingerprint of every
file you submitted. If there's ever a question about whether a file was
altered after submission, this proves it either was or wasn't.

---

## 5. Viewing what you've submitted

```
$ ls ~/submissions/assignment01/
submission-001
submission-002

$ ls -la ~/submissions/assignment01/submission-001/
total 44
drwxr-x---+ 3 root root  4096 Aug 19 09:33 .
drwxr-x---+ 3 root root  4096 Aug 19 09:33 ..
-rw-r-x---+ 1 root root 15960 Aug 19 09:33 hello
-rw-r-x---+ 1 root root    83 Aug 19 09:33 hello.c
drwxr-x---+ 2 root root  4096 Aug 19 09:33 metadata
```

Notice the files are owned by `root`, not you — this is intentional (see
below). You can read them any time, from any assignment, any past version.

> **📷 Screenshot placeholder** — *Capture `ls` and `cat` inside
> `~/submissions/.../submission-001/`.*
>
> ![Viewing a submission through the read-only view](screenshots/student-05-view.png)

---

## 6. Why you can't edit or delete a submission (and shouldn't want to)

This is expected behavior, not a glitch:

```
$ echo cheating >> ~/submissions/assignment01/submission-001/hello.c
bash: line 1: .../hello.c: Permission denied

$ rm -f ~/submissions/assignment01/submission-001/hello.c
rm: cannot remove '.../hello.c': Read-only file system
```

Your submission view is mounted **read-only at the filesystem level** — the
server refuses the write before it even checks who you are. There is no
permission you can be granted to change this, because that's the entire
point: once submitted, it's permanent. If you made a mistake, **submit
again** — your new version sits alongside the old one; nothing is ever
silently overwritten or lost.

> **📷 Screenshot placeholder** — *Capture an attempted edit/delete being
> refused, as shown above.*
>
> ![Attempted edit/delete refused](screenshots/student-06-readonly.png)

---

## 7. Common errors

| You typed | What happened | Why |
|---|---|---|
| `submit ../../etc` | `submit: invalid assignment name (use letters, digits, dot, underscore, hyphen)` | Assignment names can't contain `/` or `..` — this stops path tricks. |
| `submit assignment01 /etc` | `submit: you can only submit work from /home/<you>/assignments` | You can only submit things that are actually inside your own `~/assignments`. |
| `submit nosuchassignment` | `submit: no such assignment: nosuchassignment` / `submit: expected it at .../assignments/nosuchassignment` | The folder doesn't exist yet — check spelling, or create it first. |
| Submitting a folder containing a symlink | `submit: Submission contains a symbolic link, which is not allowed` | Symlinks are rejected outright — don't use them inside an assignment folder. |
| Submission too big / too many files | `submit: Submission too large...` / `submit: Too many files...` | Clean out build artifacts (`.o` files, binaries you don't need to submit, `node_modules/`, etc.) before submitting. |

> **📷 Screenshot placeholder** — *Capture one or two of the error messages
> above.*
>
> ![submit error messages](screenshots/student-07-errors.png)

---

## 8. FAQ

**Can another student see my work?**
No. Nobody but you and course faculty can read anything in your
`~/assignments` or `~/submissions`. Even the top-level submissions directory
on the server can't be browsed by other students — there is no way for
another student to even discover your username exists through it.

**Can I get my password reset?**
Only an administrator can do this — there's no self-service reset. Contact
your course staff.

**I submitted the wrong file/version — help?**
Just submit again. Every version is kept; nothing is deleted or overwritten.
Your receipt tells you exactly which version number you're looking at.

**Where does grading happen — do I need to do anything after `submit`?**
No. Once `submit` reports success, your work is recorded and faculty can
read it directly. There is nothing further for you to do.

---

*Questions not covered here? Ask your course administrator.*
