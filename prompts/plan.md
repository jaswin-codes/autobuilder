You are planning a small personal software project that will be built automatically, one short stage per day, by an unattended Claude Code session. The owner reviews and pushes the work themselves at the end of the week.

The raw idea is in IDEA.md in the current folder. It may be a rough, dictated note: read it for intent, not literal wording.

Write a file called PLAN.md in the current folder with EXACTLY this structure:

```
---
status: proposed
title: <short project title>
stack: <language / framework / key libraries>
test_command: <single command that runs the tests, e.g. "npm test" or "python -m pytest">
---

# <title>

## Goal
<2-4 sentences: what the finished thing does and who it is for>

## Scope
- In: <what the MVP includes>
- Out: <what is deliberately left out>

## Stages
- [ ] Stage 1: <title> — <one or two sentences of concrete deliverables>
- [ ] Stage 2: ...

## Done when
<how the owner can tell in review that the project works>

## Open questions
<anything the owner should decide before approving; "None" if nothing>
```

Rules for the stages:
- Pick the number of stages yourself: usually 3-7. Each stage must fit in one focused session of roughly 20-30 minutes of agent work and end in a working, committed state with passing tests.
- Stage 1 always scaffolds the project: folder layout, dependency file, README stub, a .gitignore, a test setup with one passing test.
- Order stages so each one builds on the last and the project is usable as early as possible.
- The final stage polishes: README with setup/run instructions, edge cases, cleanup.
- Only use tools that need no paid accounts, API keys or network services unless the idea explicitly requires one; if it does, list it under Open questions.
- Prefer a stack that runs on Windows with common tools (Python, Node, Java, C/C++).

Only write PLAN.md. Do not create any other files or write any code yet.
