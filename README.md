# Autobuilder

> Turn half-formed project ideas into working, tested code: a few small, cheap Claude Code sessions a day, while you get on with your life.

I have more project ideas than time. Autobuilder lets me write one down in a sentence (or dictate it on my phone) and have it built incrementally in the background, with a human review before anything leaves my laptop.

Drop in a project idea and approve the plan Claude writes for it. After that, every day when you open your laptop, Claude builds **one small stage** of each approved project in the background and commits it locally. You review the work at the end of the day or week and push it to GitHub yourself.

```
idea (inbox/)  ──plan──▶  PLAN.md (proposed)  ──you approve──▶  1 stage/day, local commits  ──you review──▶  git push
```

## Setup (once)

1. Requires Windows, PowerShell 5.1+, Git, and [Claude Code](https://claude.com/claude-code) installed and logged in. Set `claudePath` in `config.json` to your `claude.exe` (find it with `where.exe claude`).
2. Register the background job. It runs 5 minutes after you log in or unlock the laptop, with an hourly fallback from 08:00 to 23:00 for when waking from sleep doesn't count as an unlock. It does its work at most once per day:
   ```powershell
   .\scripts\install-task.ps1
   ```
   Remove it with `.\scripts\install-task.ps1 -Remove`.

## Daily use

```powershell
.\ab.ps1 idea "habit tracker" "A small web app where I tick off daily habits and see streaks..."
.\ab.ps1 plan                 # optional: plan it now instead of waiting for tomorrow's run
.\ab.ps1 show habit-tracker   # read the plan, and edit projects\habit-tracker\PLAN.md if you want changes
.\ab.ps1 approve habit-tracker
.\ab.ps1 status               # see every project's status and progress
.\ab.ps1 log                  # what happened today
```

**Capturing ideas on your phone:** set `"inboxDir"` in `config.json` to a OneDrive folder, for example `"C:\\Users\\you\\OneDrive\\autobuilder-inbox"`. Dictate a note on your phone and save it there as a `.txt` or `.md` file. The filename becomes the project name, and the note can be as rough as you like.

## Review and push

```powershell
.\ab.ps1 review               # new commits since your last review, plus each project's tests
.\ab.ps1 review -mark         # record that you've reviewed up to here
cd projects\habit-tracker
gh repo create habit-tracker --private --source . --push   # first time
git push                                                   # after that
```

## How it works

- **Plan:** each inbox note becomes `projects/<name>/` with its own git repo, holding `IDEA.md` and a `PLAN.md`. `PLAN.md` has a `status:`, a `test_command:` and a checklist of 3–7 stages that Claude sized itself. Planning uses `planModel` (Opus by default).
- **Build:** each run picks up to `maxStagesPerDay` approved projects, least recently worked first, and does the next unticked stage of each with `buildModel` (Sonnet by default, to save credits). Claude writes tests, commits in Conventional Commit style, ticks the stage in `PLAN.md` and leaves handoff notes in `NOTES.md` for the next day.
- **Status values:** `proposed` → `approved` → `done`. A project can also be `paused` by you, or set to `blocked` by Claude when it needs a decision from you; the reason is under `## Blocked` in that project's `NOTES.md`. Fix the problem, then run `.\ab.ps1 resume <name>`.
- **Guardrails:**
  - Claude runs headless in `dontAsk` mode, which means only the tools in `config.json`'s `allowedTools` can run. Push, remotes, history rewrites, `rm -rf` and downloads are blocked.
  - Each stage is killed after `stageTimeoutMinutes`.
  - Claude only works inside that project's folder.
  - Nothing is ever pushed automatically.
- **Logs:** `logs/<date>.md` is the daily digest. It shows each stage's result, its cost in USD, and any tool calls the allowlist denied. `logs/runs/` holds Claude's full output for each stage.

## Project layout

```
ab.ps1                  command-line entry point
config.json             models, daily limits, timeouts, tool allowlist
prompts/plan.md         instructions for turning an idea into PLAN.md
prompts/stage.md        instructions for building one stage
scripts/run-daily.ps1   the daily run: plan new ideas, build approved stages
scripts/lib.ps1         shared helpers (headless claude call, plan parsing, git)
scripts/install-task.ps1  registers the Windows scheduled task
projects/, inbox/, logs/, state/   runtime data, git-ignored
```

## Tuning credit use

In `config.json`:
- `maxStagesPerDay`: the total number of stages built per day, across all projects.
- `buildModel` / `planModel`: which model plans and which one builds.
- `stageTimeoutMinutes`: how long a single stage may run before it is stopped.
- `allowedTools`: add a `Bash(...)` rule here if a project needs a tool that isn't allowed yet.
