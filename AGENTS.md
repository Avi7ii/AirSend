# Repo Workflow Rules

- Work only inside this repository when the task is about `Localsend X`; do not edit sibling clones or worktrees unless the user explicitly asks for that.
- After each major code change, stop and wait for the user's verification instead of stacking more major changes immediately.
- Once the user confirms a major change is fixed or acceptable, create one `git commit` for that change before starting the next major change.
- Do not accumulate multiple major uncommitted refactors after user verification; commit the accepted change first, then continue.
