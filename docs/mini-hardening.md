# mini-hardening — capitano + watcher sotto systemd sul Mac mini (D1)

Eseguito il **2026-08-31** da un fleet sub-agent (task `d1-systemd-captain-watch-unit-401`).
Obiettivo: portare **capitano** (pi in tmux `fleet`) e **watcher** (pi-fleet L3) sotto
**unit systemd user** (`Restart=always`) sul Mac mini (Debian 13, ale@100.84.122.49,
Tailscale), sostituendo la combinazione precedente tmux+supervisore ad-hoc.

Riferimenti: `docs/mini-bootstrap.md` (ricetta bootstrap canonica, config rimasta invariata) ·
`docs/fleet-dispatch.md` (deploy/note dispatch) · `docs/ARCHITECTURE.md` (semantica
watcher/wake). **pi-bridge e pi-web restano servizi systemd esistenti — NON toccati.**

## Stato / acceptance criteria

| # | Criterio | Stato | Evidenza |
|---|---|---|---|
| 1 | Unit `fleet-captain.service` attiva (tmux `fleet` + pi sotto systemd, `Restart=always`) | ✅ | `systemctl --user status fleet-captain` attivo; `tmux capture-pane -p -t fleet` mostra pi v0.84.4 col footer `(opencode-go) deepseek-v4-flash • high` |
| 2 | Unit `fleet-watch.service` attiva (watcher L3, singleton, `Restart=always`) | ✅ | `systemctl --user status fleet-watch` attivo; processi `fleet-watch-run.sh` + `fleet-watch.sh --interval 3`; `.last-watcher-beat` fresco (< 10s) |
| 3 | Nessun doppio watcher (lock OK) | ✅ | `.watch.lock` = pid vivo dell'unico `fleet-watch.sh`; niente processi duplicati dopo restart |
| 4 | Restart resiliente (ciclo `systemctl --user restart`), **senza reboot kernel** | ✅ | restart di entrambe le unit una volta ciascuna → ripartenza pulita, beat fresco, zero stato perso |
| 5 | E2E live sotto systemd: dispatch via hermes → wake captain → done.json | ✅ | dispatch `cmd-1788129033` → `fleet_status` risposto, `<id>.done.json` scritto, summary nel chat-loop; verificato anche il rifiuto di un comando fuori allowlist (`cmd-1788129265` → `refused: command not allowed`) |
| 6 | `auth.json` mode 600 verificato | ✅ | `600 ale:ale` (già 600 al momento del task; chmod 600 rieseguito, nessuna modifica necessaria) |
| 7 | Boot test con reboot kernel | ⏳ *deferito* | limitazione accettata: `Restart=always` è verificato via ciclo di restart; il reboot naturale del mini lo riproverà end-to-end |

## Cosa è stato installato (deploy su mini)

| Componente | Path mini | Note |
|---|---|---|
| `fleet-captain.service` | `/home/ale/.config/systemd/user/fleet-captain.service` | unit captain (template: `scripts/fleet-captain.systemd-unit`) |
| `mini-captain-run.sh` | `/home/ale/pi-fleet/scripts/mini-captain-run.sh` | launcher captain (committato nel repo, installato nel clone) |
| `fleet-watch.service` | `/home/ale/.config/systemd/user/fleet-watch.service` | unit watcher (template: `scripts/fleet-watch.systemd-unit`) |
| `fleet-watch-run.sh` | `/home/ale/pi-fleet/scripts/fleet-watch-run.sh` | wrapper watcher (committato nel repo, installato nel clone) |

Versioni mini: pi **0.84.4** (`/usr/local/bin/pi`) · clone pi-fleet a **9653de7** (main,
T-022 incluso) · `Linger=yes` (il gestore utente systemd sopravvive alla chiusura delle
sessioni SSH) · `systemctl --user is-system-running` → `running`.

### Install/deploy (idempotente, dal MacBook)

```bash
# 1. unit dalla sorgente canonica (repo) → ~/.config/systemd/user (rinominate .service)
scp scripts/fleet-captain.systemd-unit \
    ale@100.84.122.49:~/.config/systemd/user/fleet-captain.service
scp scripts/fleet-watch.systemd-unit \
    ale@100.84.122.49:~/.config/systemd/user/fleet-watch.service

# 2. launcher/wrapper nello stesso clone usato dal captain (e dall'extension pi)
ssh ale@100.84.122.49 'mkdir -p ~/pi-fleet/scripts'
scp scripts/mini-captain-run.sh scripts/fleet-watch-run.sh ale@100.84.122.49:~/pi-fleet/scripts/

# 3. registra + abilita + avvia
ssh ale@100.84.122.49 'chmod +x ~/pi-fleet/scripts/mini-captain-run.sh ~/pi-fleet/scripts/fleet-watch-run.sh; \
    systemctl --user daemon-reload; \
    systemctl --user enable --now fleet-watch fleet-captain; \
    systemctl --user status fleet-captain fleet-watch --no-pager | head -40'
```

Nota: le unit fanno `ExecStart=` sui runner dentro `/home/ale/pi-fleet/scripts/` (come
pi-bridge → `/home/ale/pi-bridge/run.sh`): un futuro `git pull` del clone aggiorna i
runner "al prossimo restart dell'unit" — comportamento voluto (versione sempre il repo).

### Verifica

```bash
systemctl --user status fleet-captain fleet-watch --no-pager      # active (running)
systemctl --user list-units | grep -E "fleet|pi"                  # 4 unit (pi-bridge, pi-web, fleet-captain, fleet-watch)
tmux capture-pane -p -t fleet | tail -5                           # pi vivo, footer modello
cat /home/ale/.pi/fleet/.last-watcher-beat; date +%s              # beat fresco (< 10s)
ps -eo pid,ppid,cmd | grep fleet-watch | grep -v grep             # UN solo fleet-watch.sh
cat /home/ale/.pi/fleet/.watch.lock | xargs -I{} ps -p {} -o pid,cmd --no-headers   # lock = pid vivo
```

### Rollback (tornare a tmux + supervisore ad-hoc)

```bash
# stop + disable delle unit (il vecchio modus operandi resta nelle docs)
systemctl --user stop fleet-captain fleet-watch
systemctl --user disable fleet-captain fleet-watch

# captain come prima (docs/mini-bootstrap.md, ricetta canonica)
tmux kill-session -t fleet 2>/dev/null; sleep 1
tmux new-session -d -s fleet -x 200 -y 50 -c /home/ale/pi-fleet
tmux send-keys -t fleet "export PATH=/usr/local/bin:\$PATH; export PI_FLEET_CAPTAIN=1; cd /home/ale/pi-fleet && exec pi" Enter

# watcher come prima (wrapper provato)
cd /home/ale/pi-fleet
setsid bash -c "cd /home/ale/pi-fleet && while true; do bash bin/fleet-watch.sh --interval 3 || true; sleep 2; done" \
  </dev/null >/tmp/fleet-watch.log 2>&1 &
```

## Decisione: niente EnvironmentFile (600-o-niente segreti)

Il discovery del task (confermato dai processi sulla mini) è: **il provider/modello NON
vengono da env**: pi li legge dalla config `~/.pi/agent/settings.json`
(`defaultProvider: opencode-go`, `defaultModel: deepseek-v4-flash` — il footer del pane
`(opencode-go) deepseek-v4-flash • high` è la prova) e la **chiave API vive in
`~/.pi/agent/auth.json` (mode 600, mai in git)**.

Decisione presa: **un EnvironmentFile con segreti è VOLUTAMENTE NON creato**. Le unit
esportano solo `PATH` e `PI_FLEET_CAPTAIN=1` (il gate captain richiede la variabile
perché sul mini `cwd=/home/ale/pi-fleet`, non `$HOME`). `PI_DEFAULT_MODEL` NON è
impostato (sovrascriverebbe la config). Se un domani servisse un override, si usi
`Environment=PI_DEFAULT_MODEL=…` diretto nell'unit (visibile a `systemctl cat` per l'utente
ale, come per pi-bridge) — mai una variabile di servizio con segreti, perché il sistema
di unit user systemd non cifra gli EnvironmentFile.

## Cosa pulisce il launcher captain all'avvio (e cosa NO)

`mini-captain-run.sh` rimuove, a ogni start:
- `~/.pi/fleet/cmd-*.done.json` — canali di ritorno di dispatch il cui
  `dispatch-cmd.sh` non è più in polling (completato+`--cleanup` ha rimosso il trio, o
  è scaduto); mantenerli ri-sveglierebbe il captain fresco per comandi che nessuno attende.
- `~/.pi/fleet/cmd-*.needs-input.json` — richieste di wake stale iniettate mentre il
  captain precedente era morto (stesso ragionamento).

**MAI toccati**: `tasks/*.brief.md`, `<id>.json` (record audit), `<id>.log`,
`<id>.inbox/`, `branch-outcomes.jsonl`, `.wake-queue/` (coda wake durevole + ancora di
dedup dei `failed`), `.watch.*`, `captain.md`/`learnings.md`.
Nota: il watcher mantiene anche `.wake-done-<id>` — il sentinel di dedup dei done-wake
(T-025): creato al primo wake di un `<id>.done.json`, potato automaticamente quando il
marker viene consumato o quando il record audit `<id>.json` sparisce. Come `.wake-queue`,
non viene toccato dal launcher (lo gestisce solo il watcher).
Nota di sicurezza: `*.done.json` dei task REALI **non** viene rimosso — il watcher
classifica `signal: <id>.done` sulla **presenza del file**, ma (da T-025) **una sola
volta per evento** grazie al sentinel `.wake-done-<id>`; il wake perso sarebbe solo
per un task completato mentre captain E watcher erano entrambi giù (unico caso: boot
mini, differito); la coda `.wake-queue` + i file di stato coprono il resto.

## Semantica lock/beat del watcher (perché due istanze non si sovrappongono)

- `fleet-watch.sh` è un loop singleton: lock `~/.pi/fleet/.watch.lock` = PID; un nuovo
  spawn che trova un owner vivo esce `watcher: healthy pid=…` senza fork; lock stale
  (PID morto/non numerico) vengono rubati atomicamente (`fleet-lock-lib.sh`).
- Self-eviction: un watcher che perde il lock esce subito.
- Il wrapper (`fleet-watch-run.sh`) ri-spawna SOLO dopo l'exit del precedente (la trap
  EXIT rilascia il lock prima) + gap di 2s → mai due watcher insieme.
- Beat: `.last-watcher-beat` (epoch) toccato a ogni poll (~3s) = beacon di liveness
  che captain/arm controllano.

## E2E live sotto systemd (prova finale)

Dispatch via Hermes (hermes user sul mini), stesso contratto E2E-1 di T-022, ora con il
capitano sotto systemd:

```sh
hermes -z "Esegui ora: sudo /opt/fleet/hermes-dispatch.sh fleet_status"
```

(nota: hermes gira da `/srv/hermes` e DEVE chiamare il wrapper `/opt/fleet/...` via `sudo`
— la regola sudoers è `hermes ALL=(ale) NOPASSWD: /opt/fleet/hermes-dispatch.sh`; la copia
`/home/ale/bin` è per l'uso diretto di ale. Un invio che parte con cwd su `/home/ale`
fallisce con `Permission denied: '/home/ale/.git'` perché la home di ale non è traversabile
da hermes.)

Risultato: il watcher di sistema ha classificato `signal: cmd-1788129033.needs-input`, il
captain (sotto unit systemd) si è svegliato, ha eseguito `fleet_status` via `fleet_dispatch`
e ha scritto `<id>.done.json`; il wrapper ha stampato il summary nel chat-loop.
Evidenza su disco (prima del cleanup):

```jsonc
// /home/ale/.pi/fleet/cmd-1788129033.done.json
{"status":"done","summary":"**pi-fleet fleet (4)**: … fleet_status answer …"}
// record dispatch:
// /home/ale/.pi/fleet/cmd-1788129033.json → {"id":"cmd-1788129033","kind":"dispatch","state":"needs_input","summary":"dispatched: fleet_status"}
// branch-outcomes.jsonl row: {"ts":1788129034397,"taskId":"cmd-1788129033","title":"dispatch: fleet_status","verdict":"needs_input"}
// watcher triage: actionable: signal: cmd-1788129033.needs-input
```

Bonus: un dispatch fuori allowlist (`dispatch-cmd.sh --cleanup cmd-…` — flag interpretato
come dispatch di un comando non consentito, vedi sotto) è stato **rifiutato correttamente**:
`cmd-1788129265` → done.json `{"status":"failed","summary":"refused: command not allowed"}` — la
catena rifiuto funziona anch'essa sotto systemd.

## Lezione operativa: ciclo di vita dei marker dispatch (finding D1 → fix T-025)

Osservazione sul campo durante l'e2e: finché `cmd-*.done.json` resta su disco (default
`KEEP for audit` di dispatch-cmd.sh — `--cleanup` è un **flag di invio**, non un comando di
pulizia per id esistenti), il watcher classificava `signal: <id>.done` a **ogni poll** e ne
scriveva una wake in `.wake-queue` ogni ~2s → **hot-loop**: +125 file in ~4,5 min per
`cmd-1788129033.done` (seq 7→132). Era un **bug genuino del watcher** (le wake `done` non
avevano la dedup che le `failed` hanno via `_fleet_already_queued`) — **corretto in T-025**
(vedi `tests/smoke-done-wake-dedup.sh`). Comportamento odierno:

1. **Dedup dei done-wake (T-025)**: il watcher emette `signal: <id>.done` **ESATTAMENTE
   una volta per evento**. Al primo poll che vede `<id>.done.json` scrive la wake in
   `.wake-queue` (per-record `{seq, taskId, reason}`) e crea il sentinel `.wake-done-<id>`.
   I poll successivi, finché il marker persiste, **assorbono** (niente flood, niente
   respawn). Il record audit `<id>.json` non viene MAI toccato.
2. **Consumo del marker**: quando il done.json sparisce (dispatch-cmd.sh `--cleanup` dopo
   la lettura, o launcher captain a start), il poll successivo **pota il sentinel** — un
   NUOVO evento `done` per lo stesso id (nuovo dispatch / completamento reale) ri-sveglia
   il captain una volta. Il contratto di consegna è preservato: wake-once per ogni evento.
3. **`failed` invariato**: l'anchor in `.wake-queue` (`_fleet_already_queued`) resta il
   meccanismo dei failed — un solo re-wake per ciclo di ack, nessun flood.
4. **Igiene operativa (consigliata, non più necessaria per evitare il flood)**: dopo un
   dispatch, `dispatch-cmd.sh --cleanup` sul prossimo invio, oppure a mano
   `rm ~/.pi/fleet/cmd-<id>.done.json ~/.pi/fleet/cmd-<id>.needs-input.json` (tenendo
   `<id>.json` per audit). Il launcher captain continua a pulire i marker stale a ogni
   start (belt-and-braces per dispatch abbandonati). Per forzare un re-wake manuale di un
   done marker persistente: `rm ~/.pi/fleet/.wake-done-<id>`.
5. **Dotfiles (fuori da questo branch)**: far passare `--cleanup` di default dal wrapper
   `hermes-dispatch.sh` — il trio non persiste mai.

## Cleanup eseguito (step 7 del task)

- `tasks/` su mini: **nessun brief rimosso** — i 3 file (`e2e-dispatch-dotfiles-readme-n-533`,
  `remote-aggiungi-una-nota-al-re-400`, `remote-test-brief-xxx-338`) hanno TUTTI il record
  terminale vivo su disco (done/failed/aborted) → tenuti per audit.
- Flood `.wake-queue` rimosso: `fleet-wake-drain.sh --ack-through 132` (127 file spazzatura
  dell'hot-loop) + ack dei residui; lasciata in sede l'anchor 141.json del task failed.
- Marker `cmd-1788129033.done.json`/`.needs-input.json` rimossi (record audit `.json`
  mantenuto); trio `cmd-1788129265` auto-pulito dal dispatch-cmd `--cleanup` di quell'invio.
- pi-bridge/pi-web: non toccati.

## Ordine di avvio e dipendenze

`fleet-watch` prima, `fleet-captain` dopo (`After=fleet-watch.service` sull'unit
captain): il captain all'avvio (session_start) arma il watcher tramite
`fleet-watch-arm.sh`; con la unit watcher già attiva l'arm trova il lock vivo e si limita
ad attachare (`watcher: attached pid=…`). Nessuna dipendenza circolare: entrambe partono
da `default.target` (user), `network-online.target` atteso prima.

## Limitazioni accettate / note

- **Boot test kernel deferito**: `Restart=always` è verificato via ciclo di restart
  (step 5 del task), non con un reboot; la prova end-to-end al prossimo reboot naturale
  del mini resta un follow-up (la configurazione systemd user + Linger=yes lo rende
  coperto in teoria).
- Il captain sotto systemd è comunque in **tmux `fleet`**: tutte le ispezioni restano
  `tmux capture-pane`; MAI `send-keys` in un pane vivo (singolo consumatore).
- Il mini resta **command-driven** (nessun herdr → nessun wave autonomo) — invariato.
- `fleet-captain.service` usa `KillMode=process` di proposito: la SIGKILL dell'intero
  cgroup (control-group/mixed) potrebbe uccidere il server tmux e con esso **altre**
  sessioni tmux dell'utente. La trap TERM del launcher chiude solo la sessione `fleet`;
  se il launcher venisse SIGKILLato, la sessione orfana viene ripulita dallo start
  successivo (step 0 idempotente).