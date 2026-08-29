# Pi — Global agent instructions

## Delegation policy (pi-fleet) — AUTOMATIC DELEGATION

**Golden rule**: when the user asks you to DO something (read/analyze a project, modify code, implement, fix, test, refactor, research the codebase), **immediately call `fleet_launch` automatically** — without waiting for the user to type `fleet_launch`, without asking for confirmation, without asking "should I launch it as a sub-agent?". Delegation is the default; inline is the exception.

### When to answer inline (DO NOT delegate)
Only if the request falls into one of these cases:
- **Questions answerable from current context** (explanations, "which model are you using?", comparisons of what's already in the chat, summary of a report that already arrived).
- **Fleet management** (fleet_status/peek/steer/abort/attach).
- **Administration** in `~` (config, installing/updating extensions, this AGENTS.md).
- Trivial single-line fixes *in the file you're already working on in this same turn* without need for isolation.

### When to delegate (ALWAYS, automatic)
- **Any work on a project**: even just reading/analyzing ("look at my-app and tell me…"), and of course modifying, implementing, fixing, testing, refactoring.
- Requests that require more than a one-liner answer or more than one tool call on the project.
- Multiple independent tasks → **launch them in parallel** (max 5 per turn; subsequent turns uncapped), not sequentially.
- Don't do the work yourself "because it's small": if it touches a project, delegate it. The child works in parallel and the chat stays free.

### How to fill `fleet_launch`
- `title`: short task label.
- `brief`: complete instructions (goal, constraints, deliverable, what NOT to do).
- `project` (ALWAYS required): use the absolute path (`/home/user/projects/my-app`, `~/projects/my-app`) or, if `FLEET_PROJECTS_DIR` is set, a short name resolved against it (e.g. with `FLEET_PROJECTS_DIR=~/projects`, `my-app` → `~/projects/my-app`). If truly ambiguous and not inferable, ask ONE short question. Never launch without project.
- `timeoutMin`: default 360; lower for quick read-only tasks, raise if needed.
- Do NOT set `worktree: false` unless explicitly justified (default: treehouse isolation).
- **ALWAYS use the `fleet-brief` skill** to write the brief: it delegates self-recon to the child (self-alignment, self-context, self-verification, self-delivery). The captain writes only objective + constraints + delivery and launches right away: NEVER prepare context on the child's behalf (git recon, docs reading, claim inventories) nor copy summaries from stale references.

### When the task finishes
- After each `fleet_launch`, **CLOSE the turn immediately**: the chat is free, do NOT poll with `fleet_status`/`fleet_peek` to monitor. The report arrives on its own in the chat (done without interruption; failed/needs_input really wake you). Use `fleet_status`/`fleet_peek` ONLY if the user asks for them or a failed report requires it.
- The done report arrives on its own in the chat (followUp, no interruption). **The report is already complete in the message: DO NOT rewrite or expand it.** Confirm in 1-2 lines and propose next steps; full details remain in `fleet_status <id>`.
- If the task changed files, list them and **offer** a PR (only on explicit confirmation).
- If `failed`: summarize the cause and propose a fix/retry.
- If `needs_input`: answer with `fleet_steer` and resume the child.
- **Never auto-merge. Never launch a tool without project.**

## Fleet rules (reference)
- The main agent stays in `~` (HOME). Projects are reached via `FLEET_PROJECTS_DIR` if set (e.g. `~/projects`), otherwise via absolute paths.
- Each task runs in an isolated treehouse worktree; never work on the shared working tree for parallel tasks.
- Success = report in chat without LLM interruption; failed/needs_input = wake with triggerTurn. No wake for voluntary abort.
- Only `pi` tabs (no claude/codex).

## Skill creation — placement (pi-fleet workflow)
- Skills that serve OUR workflow in pi (agent + pi-fleet: brief, dispatch, task execution, etc.) must ALWAYS be created INSIDE the pi-fleet repo (`skills/<name>/SKILL.md`): shipped with the extension, auto-loaded by pi, versioned. Never create them globally.
- Global (`~/.agents/skills/`) ONLY for generic skills NOT tied to our pi-fleet workflow (e.g. i-have-adhd, grilling, caveman...).
- After adding a skill to the repo, remove any temporary local copy (single source of truth = repo).
