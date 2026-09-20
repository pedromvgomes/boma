---
description: Files rendered by gt or agtk are never hand-edited; change the spec or the definition and re-render.
---

# A generated file is changed through its source

Two tools render files into this repository, and both overwrite on the next run.

- **gt** owns `.github/workflows/ci-orchestration.yml`, `.github/dependabot.yml`,
  `.github/workflows/gt-sync.yml` and `dependabot-auto-merge.yml`. Their source is
  `.gt-repo.yaml`; re-render with `gt repo sync` and verify with `gt repo check`. The
  `ci-*` stage workflows are the exception — gt creates each once and never touches it
  again, so those are yours to edit.
- **agtk** owns `.claude/`, `CLAUDE.md`, `.mcp.json`, `.codex/`, `.agents/` and `AGENTS.md`.
  Their source is `.agentic-toolkit.yaml` plus this repo's own content under `agentic/`;
  re-render with `agtk sync`. All of that output is gitignored — if you find yourself
  editing `AGENTS.md`, you want `agentic/instructions/boma-repo.md` instead.

A hand-edit to a generated file is lost silently at the next sync and reads as drift until
then. Put only deliberate overrides in a spec: a value that merely restates gt's default
stops tracking that default the moment it is pinned.
