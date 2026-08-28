# pi-fleet

Sub-agent **visibili** per [pi-coding-agent](https://github.com/earendil-works/pi-coding-agent): delega un task, un **tab herdr reale** si apre accanto al tuo workspace con un `pi` figlio che lavora in una **worktree treehouse isolata**, la chat principale resta libera e il risultato ti arriva in chat quando il task finisce — con il wake della chat solo quando serve davvero il capitano (fallimento o input richiesto).

Sostituisce l'esperienza "Firstmate" dentro pi, senza agent esterni.

---

## Come funziona in breve

```
[tu] ──"analizza MiroFish"──► pi (main, in ~)
                                │  delega automatica (AGENTS.md)
                                ▼  fleet_launch
                     pi-fleet (estensione)
                                │  spawna (detached)
                                ▼  bin/herdr-launch.sh
                     tab herdr VISIBILE (w1:tX) + pi figlio + worktree treehouse
                                │  attesa marker in ~/.pi/fleet/<id>.json
                                │  done → summary nello stato
                                ▼
                     watcher (solo nel capitano) → report in chat:
                       · done          → followUp SENZA interruzione (parità Firstmate)
                       · failed/needs_input → wake (triggerTurn) — serve il capitano
```

- **Non sono processi figli**: ogni sub-agent è una **sessione pi indipendente** nel pane herdr (come pi-subagents, che pure crea sessioni pi separate). Il coordinamento avviene via i **file di stato condivisi in `~/.pi/fleet/`**.
- Il modello dei figli è **quello attivo del main al momento del lancio** (`ctx.model`), a meno che non ne indichi uno esplicito.
- Worktree **sempre** di default; mai merge automatici; PR solo se chiesta.

---

## Requisiti

| Componente | Versione | Note |
|---|---|---|
| [pi](https://github.com/earendil-works/pi-coding-agent) | ≥ 0.84 | il main agent |
| [herdr](https://github.com/earendil-works/herdr) | ≥ 0.8 | sessione `default` avviata; socket `~/.config/herdr/herdr.sock` |
| [treehouse](https://github.com/earendil-works/treehouse) | ≥ 2.3 | pool configurato per i repo su cui lavorerai (vedi sotto) |
| `jq` | — | `brew install jq` |
| `bash` + `python3` | — | macOS ha entrambi |
| [pi-subagents](https://github.com/nicobailon/pi-subagents) | facoltativo | registry "background-work" sotto il cofano; senza, l'estensione usa un fallback |

Sistema operativo testato: **macOS** (le assunzioni nel launcher — no `setsid`, `sed` posix, `treehouse` — sono macOS/posix).

### Preparare il pool treehouse (una volta per repo

```bash
cd ~/Documents/GitHub/<repo> && treehouse config --root ~/.treehouse && treehouse add --target .
# verifica: treehouse status → mostra le worktree disponibili
```

---

## Installazione

### 1. Clona il pacchetto

```bash
git clone git@github.com:alessandrofogli/pi-fleet.git
# oppure, se la repo è privata e usi https:
git clone https://github.com/alessandrofogli/pi-fleet.git
cd pi-fleet
```

### 2. Install (script rapido) — consigliato

```bash
./bin/setup-fleet.sh
```

Lo script (vedi sezione successiva) fa: check prerequisiti, `pi install .`, installa `pi-subagents`, scrive `~/.pi/AGENTS.md` (spostando un eventuale esistente in `.bak`), configura il `timeoutMs` 6h del subagent, e stampa i passi finali.

### 3. Install manuale

```bash
pi install .                 # da dentro la cartella del pacchetto
pi install npm:pi-subagents  # consigliato (registry background-work)
```

Poi verifica che `~/.pi/agent/settings.json` abbia (l'ordine non conta):

```jsonc
{
  "packages": [
    "npm:pi-blackhole",              // opzionale, se lo usi già
    "npm:pi-subagents",
    "../../Documents/GitHub/pi-fleet" // path creato da `pi install .`
  ],
  "subagents": { "defaultModel": "inherit" }
}
```

> **Attenzione**: il path del pacchetto locale in `settings.json` è riferito a `~/.pi/agent/`. `pi install .` lo ricalcola da sé: se hai clonato altrove, rilanci `pi install .` da dentro la cartella.

### 4. Configurazione globale (istruzioni per il main agent)

Copia il template della policy di delega (quella che fa partire la delega **automatica**):

```bash
cp templates/AGENTS.global.md ~/.pi/AGENTS.md
```

(Se hai già un `~/.pi/AGENTS.md`, uniscilo o salva una copia: lo script di setup salva automaticamente `AGENTS.md.bak`.)

Facoltativo — config del subagent (timeout 6h + attesa tool): vedi `templates/subagents.config.json` → `~/.pi/agent/extensions/subagent/config.json`.

### 5. Riavvia pi

L'estensione si carica solo all'avvio. Poi prova:

```
guarda MiroFish e dammi un riassunto del README
```

Il task parte come tab herdr visibile; a fine task il report arriva in chat.

---

## Uso

### Delegazione automatica (ti basta chiedere)

Con `~/.pi/AGENTS.md` installato, pi **chiama da solo** `fleet_launch` per qualunque lavoro su un progetto (`~/Documents/GitHub/<nome>`), senza che tu scriva `fleet_launch`:

```
mi fai un check approfondito dei modelli LLM in MiroFish? e in parallelo un check del database
```

- Task in parallelo → massimo 5 per turno, in tab separati, worktree diverse
- Il main **chiude subito il turno** dopo il lancio (niente polling)
- I report arrivano da soli in chat; `failed`/`needs_input` ti svegliano davvero

### Comandi manuali (tool dell'estensione)

| Tool | Che fa |
|---|---|
| `fleet_launch` | Lancia un task (title, brief, `project` **obbligatorio** = nome in `~/Documents/GitHub/` o path assoluto; `model` opzionale; `timeoutMin` opzionale) |
| `fleet_status` | Lista task, stati, progetti, riassunti |
| `fleet_peek <id>` | Ultimo output del pane del task (solo per task **vivi**) |
| `fleet_steer <id> <msg>` | Scrivi nella prompt del figlio (es. rispondere a `needs_input`) |
| `fleet_abort <id>` | Chiude tab, rilascia worktree, marca `aborted` |
| `fleet_attach <id>` | Porta il focus herdr sul tab del task |

### Stati di un task

`spawning → running → done | failed | aborted` (o `needs_input` con tab lasciato aperto).

Stato su disco in `~/.pi/fleet/`: `<id>.json` (stato, titolo, progetto, cwd, pane/tab, summary, changedFiles), `<id>.done.json` / `<id>.needs-input.json` (marker del figlio), `<id>.abort`, `<id>.log`, `tasks/<id>.brief.md`.

---

## Architettura

### M1 — `bin/herdr-launch.sh` (launcher)

- Risolve la workspace herdr (herdr CLI, non env), prende una **worktree** con `treehouse get --lease --no-fetch`
- Crea il **tab** (`tab create`), avvia il **pi figlio** (`agent start <nome-unico> --kind pi --model <provider/modello>` — nome agente 1–32 char, unico per task: senza questo herdr fallisce con `agent_name_taken`)
- Consegna il **brief** (con regole: cwd, detached HEAD → creare un branch `fleet/<id>-<slug>` prima di committare, done-marker JSON, summary completa in markdown)
- Attende i marker con: **retry** su `agent_pane_busy` (4×3s), **liveness-check** ogni 15s (figlio morto senza marker → `failed` in ~30s), timeout configurabile, abort via marker
- A fine task scrive stato+summary, chiude il tab, **rilascia la worktree** (l'ordine conta: `treehouse return` uccide i processi del pane)

### M2 — `extensions/index.ts` (estensione pi)

- 6 tool `fleet_*`; `fleet_launch` spawna il launcher in **detached** (double-fork python, sopravvive all'abort della chat)
- **Watcher** (poll 3s) sulle transizioni di stato:
  - `done` → nota in chat `deliverAs: followUp` **senza** `triggerTurn` (parità Firstmate: visibile, mai interruzione)
  - `failed` / `needs_input` → `triggerTurn: true` (ti sveglia davvero)
- **Seeding** all'avvio: i task già presenti **non** producono wake fantasma
- **Reconcile** all'avvio: task attivi senza pane herdr vivo → `done`/`failed`/`aborted` (con verifica dei marker)
- **Gate capitano**: l'estensione gira anche nelle sessioni figlie (caricano gli stessi settings), ma watcher/reconcile/provider sono attivi **solo** dove `cwd = $HOME` (o `PI_FLEET_CAPTAIN=1`) — altrimenti ogni figlio si sveglierebbe da solo con i `fleet_notice` degli altri task
- **Modello attivo**: `fleet_launch` passa `--model <ctx.model.id>` (modello corrente del main), non le env `PI_*` che sono statiche all'avvio
- Provider **background-work** sul registry di pi-subagents (import in try/catch → fallback `Symbol.for("pi-subagents.background-work.v1")`)

---

## Troubleshooting

| Sintomo | Causa / Fix |
|---|---|
| `agent start` con `invalid_agent_name` | nome agente > 32 char o non minuscolo → il launcher genera `f-<slug max23>-<4cifre>`, sempre valido |
| Due task in parallelo, il secondo non parte (`agent_name_taken`) | vecchi nomi `pi` duplicati → risolto con nomi unici per task |
| `agent_pane_busy` | race transitoria appena creato il tab → il launcher retry 4×3s |
| Task `spawning` fermo, tab mai creato | uscita prematura del launcher senza marca stato → ora ogni uscita chiama `fail_task` (stato `failed` con motivo) |
| Wake fantasma all'avvio | task già terminato nelle sessioni precedenti → seeding + reconcile |
| `fleet_notice` dentro un subagent ancora in esecuzione | estensione attiva anche nei figli → gate capitano (`cwd=HOME`) |
| Figlio con modello diverso dal main | `PI_*` statiche all'avvio → ora `ctx.model` (modello attivo) |
| Figlio morto e launcher in attesa 6h | liveness-check ogni 15s → `failed` in ~30s |
| Report "wall of text" | è la summary **del figlio** (il main non riscrive); il prompt figlio ora impone markdown strutturato |
| Main che fa polling dopo il lancio | `AGENTS.md`/tool guidelines: chiudere il turno dopo `fleet_launch` |

---

## Portabilità / spostare su un'altra macchina

È un unico pacchetto: estensione + launcher bash + template in un'unica cartella. Sul nuovo laptop:

```bash
git clone <repo>
cd pi-fleet && ./bin/setup-fleet.sh   # fa tutto l'install
# poi: avvia herdr, configura il pool treehouse dei repo, riavvia pi
```

Niente dipendenze assolute da una macchina: lo stato sta in `~/.pi/fleet/`, i progetti si risolvono per nome da `~/Documents/GitHub/`, la workspace herdr si scopre via CLI.

---

## Note di sicurezza

- Il repo non contiene e non deve contenere credenziali; le API key vivono in `~/.pi/agent/auth.json` (fuori dal repo).
- I task girano in worktree isolate; il figlio non modifica il working tree condiviso.
- Mai merge automatici: i file modificati vengono riportati come lista, la PR parte solo su conferma esplicita.