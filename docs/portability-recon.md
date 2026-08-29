# WIP recon — portability pass (personal/machine references)

Inventory of personal/machine/deprecated references found during recon (task portabilita-out-of-the-box).
This file is temporary and is removed by the final commit.

## To fix

1. `README.md`
   - Installation section: restructure into a single out-of-the-box path for new users
     (`pi install git:github.com/alessandrofogli/pi-fleet` → `bin/setup-fleet.sh` →
     optional `FLEET_PROJECTS_DIR` → `/reload` → smoke task).
   - "Prepare the treehouse pool": `treehouse config --root … && treehouse add --target .`
     is obsolete for the current CLI (v2.3.0 has `init` + `get --lease`/`return`; `config`/`add`
     do not exist) → replace with `treehouse init`.
2. `bin/setup-fleet.sh`
   - Italian comment `# herdr attivo?` (line 57).
   - Treehouse auto-config step uses obsolete `treehouse config/add` → feature-detect and use
     `treehouse init` (tolerate "already exists", exit 1) + warm pool via get/return.
   - Final "next steps": add `/reload`, requirements version hint (pi ≥ 0.84, herdr ≥ 0.8,
     treehouse ≥ 2.3), note that skill fleet-brief + extensions + subagent config + AGENTS.md
     are installed automatically.
3. `docs/ARCHITECTURE.md`
   - Italian leftovers: L3 table row "Watcher esterno", flow diagram ("Pi vivo?", "Pi chiuso?"),
     L3.5 section (heading "Diagramma flusso barrier", "Formato stato", "Componenti toccati",
     "Features estese", several rows/bullets/comments).
   - `{id}.json` example uses `/Users/you/...` (trips personal-path grep) and `rifattorizza-auth-042`,
     `analisi MiroFish` (Italian + personal project example) → genericize.
4. `bin/herdr-launch.sh`
   - Italian comments: lines 118 (`Legge un brief…`), 159 (`risponde con…`), 438 (`controlla ogni 15s…`).
   - Italian user-visible messages: line 432 (`timeout dopo … uccido il task`), line 497 (`rieseguo il gate…`).
5. `extensions/index.ts`
   - Line 202 comment references legacy `~/Documents/GitHub` fallback → reframe generic, keep facts.
6. `package.json`
   - `description` still Italian → translate.
7. `templates/AGENTS.global.md`
   - Already generic (old "Documents/GitHub" section was removed in e6902ac).
   - Add generic "Where to look for projects" section (FLEET_PROJECTS_DIR vs absolute paths) per brief.

## Justified leftovers

- `tests/smoke.sh:51` — Italian log string (`lascio /tmp/...`). NOT touched: brief forbids test edits
  (exception only if a test asserts the old template text). Flagged for the captain.

## Verified clean

- `git grep -niE "alessandro|fogli|/Users/|/home/alessandro"` → only README git URLs + ARCHITECTURE
  `/Users/you` placeholders (being fixed).
- `npx tsc --noEmit` baseline (run before edits, see task run).