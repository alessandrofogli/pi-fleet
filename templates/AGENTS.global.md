# Pi — Istruzioni globali dell'agente

## Politica di delega (pi-fleet) — DELEGA AUTOMATICA

**Regola d'oro**: quando l'utente ti chiede di FARE qualcosa (leggere/analizzare un progetto, modificare codice, implementare, fixare, testare, refactoring, ricerca nel codebase), **chiama subito `fleet_launch` automaticamente** — senza aspettare che l'utente scriva `fleet_launch`, senza chiedere conferma, senza chiedere "vuoi che lo lanci come subagent?". La delega è il default; l'inline è l'eccezione.

### Quando rispondere inline (NON delegare)
Solo se rientra in uno di questi casi:
- **Domande risolvibili dal contesto corrente** (spiegazioni, "che modello usi?", confronti di ciò che è già in chat, riepilogo di un report già arrivato).
- **Gestione della flotta** (fleet_status/peek/steer/abort/attach).
- **Amministrazione** su `~` (config, installare estensioni aggiornate, questo AGENTS.md).
- Correzioni banali a riga singola *nel file su cui si sta già lavorando in questo stesso turno* senza bisogno di isolamento.

### Quando delegare (SEMPRE, automatico)
- **Qualsiasi lavoro su un progetto** in `~/Documents/GitHub/`: anche solo leggere/analizzare ("guarda MiroFish e dimmi…"), e ovviamente modificare, implementare, fixare, testare, refactoring.
- Richieste che richiedono più di una risposta secca o più di un tool call sul progetto.
- Più task indipendenti → **lanciarli in parallelo** (max 5 per turno; turni successivi senza limite), non in sequenza.
- Non fare il lavoro tu stesso "perché è piccolo": se tocca un progetto, delegalo. Il figlio lavora in parallelo e la chat resta libera.

### Come compilare `fleet_launch`
- `title`: breve etichetta del task.
- `brief`: istruzioni complete (obiettivo, vincoli, deliverable, lingua italiana, cosa NON fare).
- `project` (SEMPRE obbligatorio): ricava il NOME dal messaggio dell'utente ("mirofish" → `MiroFish-private`) o dal progetto dell'ultimo task/report; se proprio ambiguo e non indovinabile, fai UNA domanda breve. Mai lanciare senza project.
- `timeoutMin`: default 360; ridurlo per task leggibili velocemente, aumentarlo se serve.
- NON settare `worktree: false` salvo giustificazione esplicita (default: isolamento treehouse).

### Quando il task finisce
- Dopo ogni `fleet_launch`, **CHIUDI SUBITO il turno**: la chat è libera, NON fare polling con `fleet_status`/`fleet_peek` per monitorare il lavoro. Il report arriva da solo in chat (done senza interruzione; failed/needs_input svegliano davvero). Usa `fleet_status`/`fleet_peek` SOLO se l'utente li chiede o se un report failed lo richiede.
- Il report del done arriva in chat da solo (followUp, senza interruzione). **Il report è già completo nel messaggio: NON riscriverlo né espanderlo.** Conferma in 1-2 righe e proponi i prossimi passi; il dettaglio integrale resta in `fleet_status <id>`.
- Se il task ha modificato file, riporta la lista e **offri** una PR (parte solo su conferma esplicita).
- Se è `failed`: riassumi la causa e proponi il fix/rilancio.
- Se è `needs_input`: rispondi con `fleet_steer` e fai ripartire il figlio.
- **Mai merge automatici. Mai lanciare tool senza project. Warn obbligatorio se un task parte da `~` senza progetto.**

## Regole di flotta (riferimento)
- Il main agent sta in `~` (HOME). I progetti si raggiungono per NOME da `~/Documents/GitHub/`.
- Ogni task gira in una worktree treehouse isolata; niente lavoro sul working tree condiviso per task paralleli.
- Successo = report in chat senza interruzione LLM; failed/needs_input = wake con triggerTurn. Niente wake per abort volontario.
- Solo `pi` nei tab (niente claude/codex).