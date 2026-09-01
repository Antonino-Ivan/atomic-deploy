# atomic-deploy

Il modo più diffuso di rilasciare è anche il peggiore: si sovrascrivono i file mentre il servizio risponde. Per qualche secondo il codice in produzione è metà vecchio e metà nuovo, e se qualcosa va storto non esiste una versione precedente a cui tornare — è stata sovrascritta.

atomic-deploy usa lo schema delle release con collegamento simbolico: ogni rilascio è una cartella nuova, il passaggio avviene sostituendo un symlink, e la versione precedente resta lì, intatta, pronta.

```
/srv/app/
├── releases/
│   ├── 20260903T101200-a1b2c3d/
│   ├── 20260904T173000-e4f5g6h/
│   └── 20260905T140000-i7j8k9l/     <- attiva
├── shared/
│   ├── .env
│   └── storage/logs/
├── hooks/
└── current -> releases/20260905T140000-i7j8k9l
```

```
$ atomic-deploy deploy --archive build.tar.gz
14:00:03  release 20260905T140000-i7j8k9l
fatto     contenuto pronto in /srv/app/releases/20260905T140000-i7j8k9l
14:00:04  hook pre-activate
fatto     current punta a 20260905T140000-i7j8k9l
fatto     controllo di salute superato al tentativo 1
14:00:07  hook post-activate
14:00:07  rimossa la release 20260901T090000-x1y2z3w
fatto     deploy completato: 20260905T140000-i7j8k9l
```

```
$ atomic-deploy rollback
fatto     current punta a 20260904T173000-e4f5g6h
fatto     rollback completato: 20260904T173000-e4f5g6h
```

Nessuna dipendenza: bash, coreutils e tar, cioè quello che c'è già su qualunque server Linux.

## Perché lo scambio è davvero atomico

`ln -sfn nuovo current` sembra fare la cosa giusta, ma cancella il collegamento e lo ricrea: fra le due operazioni esiste un istante in cui `current` non punta a niente. Una richiesta che arriva proprio lì vede un 404, e sotto carico "proprio lì" capita a ogni deploy.

atomic-deploy crea il collegamento con un nome temporaneo e poi lo rinomina:

```bash
ln -s "$release" "$APP_ROOT/.current.$$"
mv -T "$APP_ROOT/.current.$$" "$APP_ROOT/current"
```

`mv -T` su un percorso già esistente chiama `rename(2)`, che il kernel garantisce atomica: chi legge `current` vede la vecchia release oppure la nuova, mai il vuoto in mezzo.

Serve `mv` delle coreutils GNU. Su macOS: `brew install coreutils`.

## Installazione

```bash
git clone https://github.com/Antonino-Ivan/atomic-deploy.git /opt/atomic-deploy
ln -s /opt/atomic-deploy/bin/atomic-deploy /usr/local/bin/atomic-deploy
```

## Configurazione

Un file `atomic-deploy.conf` accanto al progetto, oppure indicato con `-c`.

```ini
APP_ROOT=/srv/app
KEEP_RELEASES=5
SHARED_DIRS=storage/logs storage/uploads
SHARED_FILES=.env
HEALTH_CHECK=curl -fsS --max-time 5 http://127.0.0.1:8080/health
HEALTH_RETRIES=5
HEALTH_DELAY=2
HOOKS_DIR=hooks
OWNER=app:app
```

Il file viene **letto**, non eseguito: niente sostituzione di comandi, niente espansioni, nessun codice che parte solo perché il file è stato aperto. Una chiave sconosciuta fa fallire il comando invece di restare un valore vuoto che nessuno nota.

| Chiave | Significato |
| --- | --- |
| `APP_ROOT` | radice dell'installazione, obbligatoria |
| `KEEP_RELEASES` | quante release conservare dopo il deploy (default 5) |
| `SHARED_DIRS` | cartelle che sopravvivono ai deploy, separate da spazi |
| `SHARED_FILES` | file che sopravvivono ai deploy |
| `HEALTH_CHECK` | comando eseguito dentro `current` dopo l'attivazione |
| `HEALTH_RETRIES` / `HEALTH_DELAY` | tentativi e pausa fra un tentativo e l'altro |
| `HOOKS_DIR` | cartella degli hook, relativa ad `APP_ROOT` |
| `OWNER` / `PERMISSIONS` | `chown` e `chmod` applicati alla release nuova |

## Comandi

```bash
atomic-deploy init                                  # crea l'albero e i percorsi condivisi
atomic-deploy deploy --from-dir ./build
atomic-deploy deploy --archive dist.tar.gz
atomic-deploy deploy --archive dist.tar.gz --release 1.4.2 --no-prune
atomic-deploy rollback                              # alla release precedente
atomic-deploy rollback --to 20260904T173000-e4f5g6h
atomic-deploy list
atomic-deploy current
atomic-deploy prune --keep 3
atomic-deploy status
```

| Codice di uscita | Significato |
| --- | --- |
| `0` | operazione riuscita |
| `1` | operazione fallita |
| `2` | argomenti o configurazione non utilizzabili |

## Cosa succede durante un deploy

1. Si prende il lock. Due deploy simultanei sul solito server sono il modo più rapido per ottenere una release a metà.
2. Le release incomplete rimaste da tentativi precedenti vengono rimosse.
3. Il contenuto viene montato in `releases/<nome>.incomplete`. Solo alla fine la cartella viene rinominata senza suffisso: **una estrazione interrotta non diventa mai una release attivabile**, quindi non può nemmeno diventare la destinazione di un rollback.
4. I percorsi condivisi vengono collegati a `shared/`.
5. Gira `pre-activate`. Se fallisce, la release viene rimossa e in produzione non è cambiato niente.
6. Il collegamento `current` viene sostituito atomicamente.
7. Gira il controllo di salute. **Se fallisce, `current` torna da solo alla release precedente** e il comando esce con errore.
8. Gira `post-activate`. Un fallimento qui è un avviso: la release è già online e ha già risposto.
9. Le release più vecchie vengono rimosse, mai la attiva e mai la precedente.

## Hook

Tre file eseguibili in `hooks/`, tutti facoltativi:

| Hook | Quando | Un fallimento |
| --- | --- | --- |
| `pre-activate` | sulla release nuova, prima dello scambio | ferma il deploy e rimuove la release |
| `post-activate` | dopo lo scambio e dopo il controllo di salute | è solo un avviso |
| `post-rollback` | dopo un rollback, manuale o automatico | è solo un avviso |

Il contesto arriva in variabili d'ambiente — `AD_RELEASE_PATH`, `AD_RELEASE_NAME`, `AD_PREVIOUS_RELEASE`, `AD_APP_ROOT`, `AD_SHARED_DIR`, `AD_CURRENT_LINK`, `AD_HOOK` — e non in argomenti posizionali: un hook scritto oggi continua a funzionare se domani il contesto si arricchisce.

In [`examples/hooks/`](examples/hooks) ci sono tre hook realistici: migrazioni prima dello scambio, ricarica dei servizi dopo, traccia nel log di sistema dopo un rollback.

## Il lock

Una cartella creata con `mkdir`, che è atomico su qualunque filesystem POSIX: due processi non possono crearla entrambi. Dentro c'è il PID del proprietario, che serve solo a riconoscere un lock rimasto da un processo terminato male — in quel caso viene rimosso con un avviso, invece di bloccare i deploy fino al prossimo intervento manuale.

## Uso da GitHub Actions

```yaml
- name: Pubblica
  run: |
    tar -czf dist.tar.gz -C build .
    scp dist.tar.gz deploy@server:/tmp/dist.tar.gz
    ssh deploy@server 'atomic-deploy -c /srv/app/atomic-deploy.conf deploy --archive /tmp/dist.tar.gz'
```

Se il controllo di salute non passa, il comando esce con codice 1, il job fallisce e il server è già tornato alla versione precedente da solo — senza aspettare che qualcuno legga la notifica.

## Come è fatto

| File | Responsabilità |
| --- | --- |
| `bin/atomic-deploy` | argomenti, comandi, orchestrazione, codici di uscita |
| `lib/common.sh` | log, errori, lock, lettura della configurazione, percorsi |
| `lib/release.sh` | creazione, attivazione atomica, controllo di salute, potatura |
| `lib/hooks.sh` | esecuzione degli hook con il contesto in ambiente |

Tutti gli script girano con `set -euo pipefail` e `IFS` ristretto: un deploy che prosegue dopo un errore è peggio di un deploy che non parte.

## Sviluppo

```bash
shellcheck -x bin/atomic-deploy lib/*.sh test/run-tests.sh
bash test/run-tests.sh
```

Sessanta asserzioni su alberi veri creati in cartelle temporanee: i symlink sono symlink e le rinomine sono rinomine, perché è esattamente quella la parte che deve funzionare. La suite richiede un filesystem POSIX — Linux, macOS o WSL — e lo verifica prima di iniziare, invece di produrre sessanta fallimenti senza spiegare il motivo.

## Licenza

MIT — vedi [LICENSE](LICENSE).
