# =============================================================================
# File   : remove_claude_trailer.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Remove the "Co-Authored-By: Claude ..." line from every commit message of the
#          current repository, so that GitHub does not list Claude as a contributor.
#          File contents do not change; only commit messages (and therefore all commit ids).
#
# Safety:  - refuses to run with uncommitted changes
#          - makes a local backup branch first (git branch backup-before-rewrite)
#          - checks that no message contains the trailer afterwards
#          - fixes old commit ids that are written in the .md notes (PROGRESS, HANDOVER, ...)
#          - does NOT push. It prints the two push commands for you to run.
#
# Usage (repo root, PowerShell):  .\.venv\Scripts\python.exe scripts/remove_claude_trailer.py
# Undo before pushing:            git reset --hard backup-before-rewrite
# =============================================================================
import os
import re
import subprocess
import sys

BACKUP = "backup-before-rewrite"
# sed filter: delete the trailer line (any case), then delete blank lines at the end of the message
MSG_FILTER = "sed -e '/^Co-Authored-By: Claude/Id' | sed -e :a -e '/^\\n*$/{$d;N;ba' -e '}'"


def git(*args, check=True, env=None):
    r = subprocess.run(["git", *args], capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        sys.exit(f"ERROR: git {' '.join(args)} failed:\n{r.stdout}{r.stderr}")
    return r.stdout.strip()


def main():
    root = git("rev-parse", "--show-toplevel")
    os.chdir(root)
    if git("status", "--porcelain", "--untracked-files=no"):
        sys.exit("ERROR: uncommitted changes. Commit or stash them first.")
    if git("rev-parse", "--abbrev-ref", "HEAD") != "main":
        sys.exit("ERROR: run this on the main branch.")
    if git("branch", "--list", BACKUP):
        sys.exit(f"ERROR: branch {BACKUP} exists already. Delete it or rename it first.")

    old = [l.split(" ", 1) for l in git("log", "--format=%h %s").splitlines()]
    n_trailer = len(git("log", "-i", "--grep=co-authored-by: claude", "--format=%h").splitlines())
    print(f"{len(old)} commits, {n_trailer} with a Claude co-author line")

    git("branch", BACKUP)
    print(f"backup branch '{BACKUP}' created (undo: git reset --hard {BACKUP})")

    env = dict(os.environ, FILTER_BRANCH_SQUELCH_WARNING="1")
    git("filter-branch", "-f", "--msg-filter", MSG_FILTER, "--tag-name-filter", "cat", "--", "--all", env=env)

    # the backup branch still has them on purpose; check only the rewritten history
    left = [h for h in git("log", "-i", "--grep=co-authored-by: claude", "--format=%h", "main", "--tags").splitlines()]
    if left:
        sys.exit(f"ERROR: {len(left)} commits still have the trailer: {left}")
    new = [l.split(" ", 1) for l in git("log", "main", "--format=%h %s").splitlines()]
    if [s for _, s in old] != [s for _, s in new]:
        sys.exit("ERROR: commit subjects changed unexpectedly; check with 'git log main' and the backup branch.")
    if git("diff", "--stat", BACKUP, "main"):
        sys.exit("ERROR: file contents differ from the backup. Do not push. git reset --hard " + BACKUP)
    print("OK: no trailer left, same subjects, identical file contents")

    # old commit ids written in the notes -> new ids (matched by subject, same order)
    mapping = {o[0]: n[0] for o, n in zip(old, new)}
    changed = []
    for dirpath, _, files in os.walk(root):
        if any(part in dirpath for part in (".git", "third_party", ".venv", "build", "node_modules")):
            continue
        for f in files:
            if not f.endswith(".md"):
                continue
            path = os.path.join(dirpath, f)
            text = open(path, encoding="utf-8").read()
            new_text = re.sub(r"\b[0-9a-f]{7}\b", lambda m: mapping.get(m.group(0), m.group(0)), text)
            if new_text != text:
                open(path, "w", encoding="utf-8", newline="").write(new_text)
                changed.append(os.path.relpath(path, root))
    if changed:
        git("add", *changed)
        git("commit", "-m", "Update commit ids in the notes after the history cleanup")
        print("updated commit ids in:", ", ".join(changed))

    print("\nDone locally. Nothing was pushed. To publish the cleaned history to your private repo:")
    print("  git push --force-with-lease origin main")
    print("  git push --force origin --tags")


if __name__ == "__main__":
    main()
