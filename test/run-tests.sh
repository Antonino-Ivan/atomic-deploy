#!/usr/bin/env bash
#
# Test di integrazione: ogni caso costruisce un albero vero in una cartella
# temporanea ed esercita il comando come lo userebbe un server. Non ci sono
# finzioni — i symlink sono symlink e le rinomine sono rinomine, perche' e'
# esattamente quella la parte che deve funzionare.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
BIN="$ROOT/bin/atomic-deploy"

PASSED=0
FAILED=0
WORK=""

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; [ $# -ge 2 ] && printf '        %s\n' "$2"; }

assert_equals() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "atteso '$3', ottenuto '$2'"; fi
}

assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "il testo non contiene '$3'" ;;
  esac
}

assert_symlink() {
  if [ -L "$2" ]; then pass "$1"; else fail "$1" "$2 non e' un collegamento simbolico"; fi
}

assert_exists() {
  if [ -e "$2" ]; then pass "$1"; else fail "$1" "$2 non esiste"; fi
}

assert_missing() {
  if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "$2 esiste e non dovrebbe"; fi
}

assert_status() {
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1" "atteso codice $3, ottenuto $2"; fi
}

# --- impianto ---------------------------------------------------------------

setup() {
  WORK="$(mktemp -d)"
  APP="$WORK/srv/app"
  SRC="$WORK/sorgente"
  CONF="$WORK/atomic-deploy.conf"
  mkdir -p "$APP" "$SRC"
  printf 'versione uno\n' > "$SRC/app.txt"
  mkdir -p "$SRC/storage"
  cat > "$CONF" <<CONFIG
APP_ROOT=$APP
KEEP_RELEASES=3
SHARED_DIRS=storage/logs storage/uploads
SHARED_FILES=.env
HEALTH_RETRIES=1
HEALTH_DELAY=0
CONFIG
}

deploy() { "$BIN" -c "$CONF" deploy --from-dir "$SRC" "$@" >/dev/null 2>&1; }
run_cmd() { "$BIN" -c "$CONF" "$@" 2>&1; }

hook() {
  local name="$1" body="$2"
  mkdir -p "$APP/hooks"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$APP/hooks/$name"
  chmod +x "$APP/hooks/$name"
}

section() { printf '\n%s\n' "$1"; }

# --- casi -------------------------------------------------------------------

test_init() {
  section "init"
  setup
  run_cmd init >/dev/null
  assert_exists "crea releases/" "$APP/releases"
  assert_exists "crea shared/" "$APP/shared"
  assert_exists "crea le cartelle condivise" "$APP/shared/storage/logs"
  assert_exists "crea i file condivisi" "$APP/shared/.env"
  cleanup
}

test_primo_deploy() {
  section "primo deploy"
  setup
  deploy --release r1 --no-health
  assert_symlink "current e' un collegamento" "$APP/current"
  assert_equals "current punta alla release" "$(basename "$(readlink "$APP/current")")" "r1"
  assert_equals "il contenuto e' pubblicato" "$(cat "$APP/current/app.txt")" "versione uno"
  assert_equals "current stampa il nome" "$(run_cmd current)" "r1"
  cleanup
}

test_percorsi_condivisi() {
  section "percorsi condivisi"
  setup
  deploy --release r1 --no-health
  assert_symlink "la cartella condivisa e' collegata" "$APP/current/storage/logs"
  assert_symlink "il file condiviso e' collegato" "$APP/current/.env"

  printf 'SEGRETO=42\n' > "$APP/shared/.env"
  printf 'riga di log\n' > "$APP/shared/storage/logs/app.log"
  deploy --release r2 --no-health

  assert_equals "il file condiviso sopravvive al deploy" "$(cat "$APP/current/.env")" "SEGRETO=42"
  assert_exists "i log sopravvivono al deploy" "$APP/current/storage/logs/app.log"
  cleanup
}

test_secondo_deploy_e_rollback() {
  section "secondo deploy e rollback"
  setup
  deploy --release r1 --no-health
  printf 'versione due\n' > "$SRC/app.txt"
  deploy --release r2 --no-health

  assert_equals "current passa alla nuova release" "$(run_cmd current)" "r2"
  assert_equals "il contenuto e' aggiornato" "$(cat "$APP/current/app.txt")" "versione due"

  run_cmd rollback >/dev/null
  assert_equals "il rollback torna alla precedente" "$(run_cmd current)" "r1"
  assert_equals "torna anche il contenuto" "$(cat "$APP/current/app.txt")" "versione uno"
  cleanup
}

test_rollback_mirato() {
  section "rollback verso una release specifica"
  setup
  deploy --release r1 --no-health
  deploy --release r2 --no-health
  deploy --release r3 --no-health

  run_cmd rollback --to r1 >/dev/null
  assert_equals "torna alla release indicata" "$(run_cmd current)" "r1"

  run_cmd rollback --to inesistente >/dev/null 2>&1
  assert_status "una release inesistente fallisce" "$?" 1
  assert_equals "current resta invariata dopo il fallimento" "$(run_cmd current)" "r1"
  cleanup
}

test_list_e_status() {
  section "list e status"
  setup
  deploy --release r1 --no-health
  deploy --release r2 --no-health

  local elenco
  elenco="$(run_cmd list)"
  assert_contains "list elenca le release" "$elenco" "r1"
  assert_contains "list segna quella attiva" "$elenco" "* r2"

  local stato
  stato="$(run_cmd status)"
  assert_contains "status riporta la release attiva" "$stato" "attiva        r2"
  assert_contains "status riporta la precedente" "$stato" "precedente    r1"
  cleanup
}

test_prune() {
  section "prune"
  setup
  local n
  for n in 1 2 3 4 5 6; do
    deploy --release "r$n" --no-prune --no-health
  done
  assert_equals "sei release presenti" "$(run_cmd list | grep -c .)" "6"

  run_cmd prune --keep 3 >/dev/null
  local rimaste
  rimaste="$(run_cmd list | grep -c .)"
  if [ "$rimaste" -le 4 ]; then pass "prune riduce il numero di release"; else fail "prune riduce il numero di release" "rimaste $rimaste"; fi
  assert_exists "prune non tocca la release attiva" "$APP/releases/r6"
  assert_exists "prune non tocca la precedente" "$APP/releases/r5"
  assert_missing "prune rimuove le piu' vecchie" "$APP/releases/r1"
  cleanup
}

test_hook_pre_activate() {
  section "hook pre-activate"
  setup
  deploy --release r1 --no-health

  # Le virgolette singole sono volute: il corpo dell'hook deve finire nel file
  # senza essere espanso qui, perche' le variabili le riceve al momento in cui
  # atomic-deploy lo esegue.
  # shellcheck disable=SC2016
  hook pre-activate 'printf "%s\n" "$AD_RELEASE_NAME" > "$AD_APP_ROOT/visto-da-pre"; exit 0'
  deploy --release r2 --no-health
  assert_equals "l'hook riceve il nome della release" "$(cat "$APP/visto-da-pre")" "r2"

  hook pre-activate 'exit 3'
  deploy --release r3 --no-health
  assert_status "un pre-activate fallito fa fallire il deploy" "$?" 1
  assert_equals "current non cambia se pre-activate fallisce" "$(run_cmd current)" "r2"
  assert_missing "la release rifiutata viene rimossa" "$APP/releases/r3"
  cleanup
}

test_hook_post_activate() {
  section "hook post-activate"
  setup
  # shellcheck disable=SC2016
  hook post-activate 'printf "%s|%s\n" "$AD_HOOK" "$AD_RELEASE_NAME" > "$AD_APP_ROOT/visto-da-post"'
  deploy --release r1 --no-health
  assert_equals "post-activate gira dopo l'attivazione" "$(cat "$APP/visto-da-post")" "post-activate|r1"
  cleanup
}

test_hook_non_eseguibile() {
  section "hook non eseguibile"
  setup
  mkdir -p "$APP/hooks"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$APP/hooks/pre-activate"
  chmod -x "$APP/hooks/pre-activate"

  local output
  output="$("$BIN" -c "$CONF" deploy --from-dir "$SRC" --release r1 --no-health 2>&1)"
  assert_status "il deploy prosegue" "$?" 0
  assert_contains "avvisa che l'hook non e' eseguibile" "$output" "non eseguibile"
  cleanup
}

test_health_check_rollback() {
  section "controllo di salute con rollback automatico"
  setup
  deploy --release r1 --no-health

  cat > "$CONF" <<CONFIG
APP_ROOT=$APP
KEEP_RELEASES=3
SHARED_DIRS=storage/logs
SHARED_FILES=.env
HEALTH_CHECK=test -f nonesiste.txt
HEALTH_RETRIES=2
HEALTH_DELAY=0
CONFIG

  deploy --release r2
  assert_status "un controllo di salute fallito fa fallire il deploy" "$?" 1
  assert_equals "torna automaticamente alla release precedente" "$(run_cmd current)" "r1"
  cleanup
}

test_health_check_superato() {
  section "controllo di salute superato"
  setup
  cat > "$CONF" <<CONFIG
APP_ROOT=$APP
KEEP_RELEASES=3
SHARED_FILES=.env
HEALTH_CHECK=test -f app.txt
HEALTH_RETRIES=2
HEALTH_DELAY=0
CONFIG

  deploy --release r1
  assert_status "il deploy riesce quando il controllo passa" "$?" 0
  assert_equals "la release resta attiva" "$(run_cmd current)" "r1"
  cleanup
}

test_deploy_da_archivio() {
  section "deploy da archivio"
  setup
  local archivio="$WORK/pacchetto.tar.gz"
  tar -czf "$archivio" -C "$SRC" .
  "$BIN" -c "$CONF" deploy --archive "$archivio" --release r1 --no-health >/dev/null 2>&1
  assert_status "il deploy da archivio riesce" "$?" 0
  assert_equals "il contenuto e' quello dell'archivio" "$(cat "$APP/current/app.txt")" "versione uno"
  cleanup
}

test_lock() {
  section "lock"
  setup
  deploy --release r1 --no-health

  mkdir -p "$APP/.deploy.lock"
  printf '%s' "$$" > "$APP/.deploy.lock/pid"
  local output
  output="$("$BIN" -c "$CONF" deploy --from-dir "$SRC" --release r2 --no-health 2>&1)"
  local status=$?
  assert_status "un deploy concorrente viene rifiutato" "$status" 1
  assert_contains "spiega che un deploy e' gia' in corso" "$output" "deploy e' in corso"

  printf '999999' > "$APP/.deploy.lock/pid"
  deploy --release r3 --no-health
  assert_status "un lock orfano non blocca il deploy" "$?" 0
  cleanup
}

test_release_incompleta() {
  section "release incompleta"
  setup
  mkdir -p "$APP/releases/vecchia.incomplete"
  deploy --release r1 --no-health
  assert_missing "le release incomplete vengono rimosse" "$APP/releases/vecchia.incomplete"
  assert_equals "le incomplete non compaiono in list" "$(run_cmd list | grep -c .)" "1"
  cleanup
}

test_configurazione() {
  section "configurazione"
  setup
  local output

  output="$("$BIN" -c "$WORK/assente.conf" status 2>&1)"
  assert_status "una configurazione mancante e' un errore" "$?" 1
  assert_contains "dice quale file manca" "$output" "non trovata"

  printf 'APP_ROOT=%s\nCHIAVE_STRANA=1\n' "$APP" > "$WORK/strana.conf"
  output="$("$BIN" -c "$WORK/strana.conf" status 2>&1)"
  assert_status "una chiave sconosciuta e' un errore" "$?" 1
  assert_contains "nomina la chiave sconosciuta" "$output" "CHIAVE_STRANA"

  printf 'KEEP_RELEASES=2\n' > "$WORK/senza-root.conf"
  output="$("$BIN" -c "$WORK/senza-root.conf" status 2>&1)"
  assert_contains "APP_ROOT e' obbligatorio" "$output" "APP_ROOT"

  printf 'APP_ROOT=%s\nKEEP_RELEASES=molte\n' "$APP" > "$WORK/keep.conf"
  output="$("$BIN" -c "$WORK/keep.conf" status 2>&1)"
  assert_contains "KEEP_RELEASES deve essere un numero" "$output" "intero"

  printf 'APP_ROOT="%s"\n' "$APP" > "$WORK/virgolette.conf"
  output="$("$BIN" -c "$WORK/virgolette.conf" status 2>&1)"
  assert_contains "le virgolette attorno al valore vengono tolte" "$output" "radice        $APP"
  cleanup
}

test_argomenti() {
  section "argomenti"
  setup
  local output

  output="$(run_cmd inesistente)"
  assert_status "un comando sconosciuto e' un errore di uso" "$?" 2
  assert_contains "nomina il comando sconosciuto" "$output" "inesistente"

  output="$(run_cmd deploy)"
  assert_status "deploy senza sorgente e' un errore di uso" "$?" 2
  assert_contains "spiega quale opzione serve" "$output" "--from-dir"

  output="$("$BIN" --help)"
  assert_status "l'aiuto esce con zero" "$?" 0
  assert_contains "l'aiuto elenca i comandi" "$output" "rollback"

  output="$("$BIN" version)"
  assert_contains "version stampa la versione" "$output" "atomic-deploy"
  cleanup
}

# --- esecuzione -------------------------------------------------------------

printf 'atomic-deploy — test di integrazione\n'
printf 'bash %s\n' "${BASH_VERSION}"

# Preflight: senza symlink veri e senza `mv -T` la suite fallirebbe ovunque
# senza dire perche'. Meglio un messaggio solo che sessanta asserzioni rosse.
preflight="$(mktemp -d)"
mkdir -p "$preflight/bersaglio"
if ! ln -s "$preflight/bersaglio" "$preflight/prova" 2>/dev/null || [ ! -L "$preflight/prova" ]; then
  rm -rf "$preflight"
  printf '\nQuesto sistema non crea collegamenti simbolici reali.\n'
  printf 'atomic-deploy richiede un filesystem POSIX: Linux, macOS o WSL.\n'
  exit 1
fi
if ! mv -T "$preflight/prova" "$preflight/prova2" 2>/dev/null; then
  rm -rf "$preflight"
  printf '\nmv -T non è disponibile: servono le coreutils GNU.\n'
  exit 1
fi
rm -rf "$preflight"

test_init
test_primo_deploy
test_percorsi_condivisi
test_secondo_deploy_e_rollback
test_rollback_mirato
test_list_e_status
test_prune
test_hook_pre_activate
test_hook_post_activate
test_hook_non_eseguibile
test_health_check_rollback
test_health_check_superato
test_deploy_da_archivio
test_lock
test_release_incompleta
test_configurazione
test_argomenti

printf '\n%s superati, %s falliti\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
