---
name: fleet-brief
description: 'Template di brief per fleet_launch che delega la self-recon al sub-agent. Il capitano scrive SOLO obiettivo + vincoli + consegna e lancia subito, senza preparare contesto (git recon, lettura docs, inventario claim): il figlio fa da solo self-alignment, self-context, self-verification e self-delivery. Da usare per OGNI fleet_launch.'
license: MIT
metadata:
  tags: "fleet, brief, delegation, template, pi-fleet"
  category: "workflow"
---

# fleet-brief — lancio immediato con self-recon delegata

## Perché esiste

Prima di lanciare un task il capitano tende a fare lavoro che il figlio può fare da solo: git recon del repo, lettura di documentazione/reference, inventario dei claim da verificare, controlli pre-push. Questo ritarda il lancio e, peggio, il contesto preparato dal capitano può essere **obsoleto o sbagliato** (es. reference di task passati ≠ stato attuale). La regola: **il capitano non prepara mai il contesto al posto del figlio**.

## Come si scrive un brief (4 fasi, tutte delegate)

Il brief istruisce IL FIGLIO a eseguire le 4 fasi; il capitano scrive solo:

1. **Obiettivo** — cosa deve essere vero alla fine (1-3 righe).
2. **Vincoli** — cosa NON toccare, base/HEAD, scope, rete/credenziali.
3. **Consegna** — dove va il risultato (report in chat, commit+push, marker), con autorizzazione esplicita se serve push/merge.
4. **Sospetti noti** (opzionale) — 2-3 claim dubbi da verificare, MAI un inventario completo.

### Fase 1 — Self-alignment (dentro il brief)
```bash
git fetch origin
git checkout -b fleet/<taskid>-<slug> origin/main
git rev-parse HEAD   # == origin/main
git status -sb       # segnala se qualcosa è sporco fuori worktree
```
Il figlio segnala: rami pendenti non merged, base diversa da origin/main, file sporchi nel checkout principale. NON risolve da solo: riporta.

### Fase 2 — Self-context (dentro il brief)
"Il contesto lo costruisci tu: leggi tu README/docs/report passati e confrontali col codice. Se una descrizione che ti ho dato non torna con il codice, segnalalo e parti dalla verità (evidenza `file:riga`)." Mai copiare nel brief riassunti presi da context obsoleti.

### Fase 3 — Self-verification (dentro il brief)
Per ogni claim del risultato: comando grep/esecuzione che lo prova (es. `grep -n triggerTurn extensions/index.ts`, `grep -c registerTool extensions/index.ts`, `npx tsc --noEmit`). Il report cita `file:riga` o "NON TROVATO".

### Fase 4 — Self-delivery (dentro il brief, se con merge/push)
Prima di pushare: status pulito, elenco di ciò che si sta per pushare, niente file estranei (es. `.treehouse/`, `node_modules/`), niente `--force`. In caso di push rifiutato o conflitti: STOP, non forzare, riporta.

## Esempio reale (avvenuto oggi, cleanup README pi-fleet)

Prima del pattern: 2 bash di git recon + analisi reference prima di scrivere il brief (4-5 tool call pre-lancio).
Con il pattern: il brief conteneva le 4 fasi + obiettivo/vincoli/consegna; il figlio ha fatto da solo allineamento base, lettura README vs codice, verifica claim (12 tool, triggerTurn, double-fork) e consegna con merge+push. Il capitano: 1 fleet_launch, zero pre-work.

## Checklist brief minimo

- [ ] Obiettivo in 1-3 righe (cosa deve essere VERO alla fine)
- [ ] Base/HEAD esplicito: "align a origin/main, verifica HEAD"
- [ ] Vincoli: cosa NON toccare, scope limitato
- [ ] Consegna + autorizzazione push/merge esplicita SE serve (mai implicita)
- [ ] "Self-context: leggiti tu i file, se la mia descrizione non torna parti dalla verità"
- [ ] 1-2 sospetti noti max, mai inventari completi