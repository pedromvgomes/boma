---
description: Merges are squashed with the PR title as the commit subject and a blank body, so the PR title must be a conventional commit.
---

# The PR title is the commit that lands

This repository merges by squash, with `squash_title: pr_title` and `squash_message: blank`.
The pull-request title becomes the subject of the commit on `main`, and the body is empty.

So the PR title must be a valid conventional commit — `<type>(<scope>): <subject>` — using
one of the types gt enforces: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`. gt validates it on `edited` as well as on push, so a
rejected title can be corrected without an unrelated commit.

Anything a reader of `git log` needs has to be in that one line, or in the code and the
`docs/adr/` entry it points at. The PR description is not preserved.

Never add an authoring or co-authorship trailer to a commit message or a PR description.
