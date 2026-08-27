# Screenshot checklist

Drop image files here using the exact names below and they'll appear
automatically in `student_guide.md` / `faculty_guide.md` wherever the
matching placeholder is — no other edits needed. PNG or JPG both work; PNG
is recommended for terminal text (sharper, no compression artifacts).

## Student guide

- [ ] `student-01-directories.png` — `ls -la ~` showing `assignments` and `submissions`
- [ ] `student-02-login.png` — SSH login / forced password change
- [ ] `student-03-editing.png` — editing/compiling inside `~/assignments`
- [ ] `student-04-submit.png` — a real `submit` command and its output
- [ ] `student-05-view.png` — `ls`/`cat` inside `~/submissions/.../submission-001/`
- [ ] `student-06-readonly.png` — an edit/delete attempt being refused
- [ ] `student-07-errors.png` — one or two `submit` error messages

## Faculty guide

- [ ] `faculty-01-login.png` — SSH login / forced password change
- [ ] `faculty-02-access.png` — denied bare `ls /srv/submissions`, then a successful `ls`/`cat` of one student
- [ ] `faculty-03-verify.png` — `sha256sum -c metadata/MANIFEST.sha256` succeeding
- [ ] `faculty-04-readonly.png` — an edit attempt being refused
- [ ] `faculty-05-assignment-check.png` — `assignment-check ASSIGNMENT` and `--list-assignments` output

## Notes

- Crop out anything sensitive that isn't relevant to the shot (other
  students' usernames scrolled above in terminal history, etc.).
- The example transcripts in both guides use a temporary test account
  (`demo01`) and a real faculty account (`pta1`) captured directly from the
  server — your own screenshots don't need to match those usernames, just
  the shape of the command and output.
