# Autobuilder

> Turn half-formed project ideas into working, tested code: a few small, cheap Claude Code sessions a day, while you get on with your life.

I have more project ideas than time. Autobuilder lets me write one down in a sentence (or dictate it on my phone) and have it built incrementally in the background, with a human review before anything leaves my laptop.

Drop in a project idea and approve the plan Claude writes for it. After that, every day when you open your laptop, Claude builds **one small stage** of each approved project in the background and commits it locally. You review the work at the end of the day or week and push it to GitHub yourself.

```
idea (inbox/)  ──plan──▶  PLAN.md (proposed)  ──you approve──▶  1 stage/day, local commits  ──you review──▶  git push
```

## Setup (once)

1. Requires Windows, PowerShell 5.1+, Git for Windows 2.31+, [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Linux containers, WSL 2 backend) and [Claude Code](https://claude.com/claude-code) installed and logged in. Set `claudePath` in `config.json` to your `claude.exe` (find it with `where.exe claude`).
2. Register the background job. It runs 5 minutes after you log in or unlock the laptop, with an hourly fallback from 08:00 to 23:00 for when waking from sleep doesn't count as an unlock. It does its work at most once per day:
   ```powershell
   .\scripts\install-task.ps1
   ```
   Remove it with `.\scripts\install-task.ps1 -Remove`.
3. Let Docker Desktop start when you sign in (Settings → General). The first build run creates the sandbox image `autobuilder-sandbox:1` from `docker/sandbox.Dockerfile`; to do it up front: `docker build -t autobuilder-sandbox:1 -f docker/sandbox.Dockerfile docker`.

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
- **Build:** each run works through approved projects, least recently worked first, doing the next unticked stage of each (or up to `stages_per_day` stages, if the project's `PLAN.md` front matter sets it), up to `maxStagesPerDay` stages in total with `buildModel` (Sonnet by default, to save credits). Claude writes tests, commits in Conventional Commit style, ticks the stage in `PLAN.md` and leaves handoff notes in `NOTES.md` for the next day.
- **Status values:** `proposed` → `approved` → `done`. A project can also be `paused` by you, or set to `blocked` by Claude when it needs a decision from you; the reason is under `## Blocked` in that project's `NOTES.md`. Fix the problem, then run `.\ab.ps1 resume <name>`.
- **Guardrails:**
  - Claude runs headless in `dontAsk` mode, which means only the tools in `config.json`'s `allowedTools` can run. Push, remotes, history rewrites, `rm -rf` and downloads are blocked.
  - Each stage is killed after `stageTimeoutMinutes`.
  - Planning reads untrusted inbox text, so it runs with `planAllowedTools` only (read the project folder, write `PLAN.md`, no shell). Building uses `allowedTools` and only runs after you approve a plan.
  - File access is scoped to the project folder, with extra denies for `~/.claude`, `~/.ssh`, `~/.config` and the project's `.git/` folder.
  - `ab.ps1 review` only runs a plan's `test_command` if it is a plain test runner, and runs it in the sandbox.
  - Nothing is ever pushed automatically.
- **Logs:** `logs/<date>.md` is the daily digest. It shows each stage's result, its cost in USD, and any tool calls the allowlist denied. `logs/runs/` holds Claude's full output for each stage.

## Security: what the build sandbox isolates

Every command that runs project code during a build stage (Python, Node/npm, tests, compilers, `make`) goes through `sandbox <command>`, which runs it in a fresh Docker container. `allowedTools` has no `python`, `node`, `npm` or other interpreter rule, and the runner refuses to start a build stage if one is added. If Docker is not installed or not running, the daily run stops with a clear message in the log and a notification; it never falls back to running code on the host. `ab.ps1 review` runs each project's tests in the same sandbox.

**Isolated (inside the container):**
- Filesystem: only `projects/<name>/` is mounted, at `/work`, with its `.git/` folder read-only. The rest of the disk, your home folder, `~/.claude`, SSH keys and other projects are not visible. The image's own filesystem is read-only; `/tmp` is a 1 GB scratch area that is thrown away.
- Network: none (`--network none`), except for exactly `npm ci --ignore-scripts`, `npm install --ignore-scripts <packages>` and `pip install -r requirements.txt`, which get outbound network to fetch packages.
- Privileges: runs as user 1000 (not root), with all Linux capabilities dropped and `no-new-privileges`.
- Limits (`config.json` → `sandbox`): `cpus`, `memory` (no extra swap), `pidsLimit`, and `stepTimeoutMinutes` per command; stragglers are removed after each stage.

**Not isolated (still runs on the host, as you):**
- Claude Code itself, with its file tools (confined to the project folder) and the allowlisted shell commands: `git` (add, commit, diff, log, show, mv, rm, status, rev-parse) and simple read-only/file utilities (`ls`, `cat`, `head`, `tail`, `grep`, `wc`, `mkdir`, `touch`, `echo`, `pwd`, `which`). Git hooks and `core.fsmonitor` are switched off for these calls.
- The runner scripts (PowerShell) and Docker Desktop.

**Remaining risk:**
- The project folder is writable from the container, so code in it can change the project's files (not its git history or config). Review commits before you run the project yourself on the host or push it.
- During the three dependency-install commands the container has network access; a malicious package can then read and send out the project folder's contents (nothing else is mounted).
- A container escape via a Docker Desktop, WSL 2 kernel or Hyper-V bug would reach the host. Keep Docker Desktop updated.
- The sandbox image has only Python 3.12, Node.js/npm and gcc/g++/make. For other stacks, build your own image and set `sandbox.image`.

## Project layout

```
ab.ps1                  command-line entry point
config.json             models, daily limits, timeouts, tool allowlist
prompts/plan.md         instructions for turning an idea into PLAN.md
prompts/stage.md        instructions for building one stage
scripts/run-daily.ps1   the daily run: plan new ideas, build approved stages
scripts/lib.ps1         shared helpers (headless claude call, Docker sandbox, plan parsing, git)
scripts/sandbox.ps1     runs one build command in the sandbox (called via scripts/bin/sandbox)
docker/sandbox.Dockerfile  the sandbox image: Python 3.12, Node.js/npm, gcc/make
tests/                  Pester tests (Docker is mocked): Invoke-Pester -Path tests
scripts/install-task.ps1  registers the Windows scheduled task
projects/, inbox/, logs/, state/   runtime data, git-ignored
```

## Tuning credit use

In `config.json`:
- `maxStagesPerDay`: the total number of stages built per day, across all projects. A project gets one stage a day unless its `PLAN.md` sets `stages_per_day: N`; an unfinished stage is not retried the same day.
- `buildModel` / `planModel`: which model plans and which one builds.
- `stageTimeoutMinutes`: how long a single stage may run before it is stopped.
- `allowedTools` (build) and `planAllowedTools` (plan): keep the plan list shell-free. Don't add interpreters or build tools to `allowedTools`; they run as `sandbox <command>`, and the runner refuses a build stage whose list would run them on the host.
- `sandbox`: the container image and per-command limits (`cpus`, `memory`, `pidsLimit`, `stepTimeoutMinutes`).
