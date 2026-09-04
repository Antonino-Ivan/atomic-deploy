# shellcheck shell=bash
# Funzioni condivise: log, errori, lock, lettura della configurazione.

AD_COLOR_ENABLED=0
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  AD_COLOR_ENABLED=1
fi

ad::paint() {
  local code="$1" text="$2"
  if [ "$AD_COLOR_ENABLED" -eq 1 ]; then
    printf '\033[%sm%s\033[0m' "$code" "$text"
  else
    printf '%s' "$text"
  fi
}

ad::log() { printf '%s  %s\n' "$(ad::paint 2 "$(date -u +%H:%M:%S)")" "$*" >&2; }
ad::ok() { printf '%s  %s\n' "$(ad::paint 32 'fatto ')" "$*" >&2; }
ad::warn() { printf '%s  %s\n' "$(ad::paint 33 'avviso')" "$*" >&2; }

# L'uscita passa sempre da qui: un messaggio che non nomina la causa costringe
# a rileggere lo script alle tre di notte.
ad::die() {
  printf '%s  %s\n' "$(ad::paint 31 'errore')" "$*" >&2
  exit "${AD_EXIT_CODE:-1}"
}

ad::require_command() {
  local missing=0 command
  for command in "$@"; do
    if ! command -v "$command" >/dev/null 2>&1; then
      ad::warn "comando non disponibile: $command"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || ad::die "servono i comandi elencati sopra"
}

# ---------------------------------------------------------------------------
# Configurazione
# ---------------------------------------------------------------------------

# Chiavi ammesse. Il file di configurazione viene letto riga per riga e non
# eseguito: un file di deploy non deve poter lanciare codice solo perche' e'
# stato letto, e una chiave scritta male deve fallire subito invece di restare
# un valore vuoto che nessuno nota.
# Array e non stringa: lo script gira con IFS ristretto a newline e tab, quindi
# un elenco separato da spazi non verrebbe suddiviso e nessuna chiave
# risulterebbe valida.
AD_CONFIG_KEYS=(
  APP_ROOT KEEP_RELEASES SHARED_DIRS SHARED_FILES
  HEALTH_CHECK HEALTH_RETRIES HEALTH_DELAY
  HOOKS_DIR OWNER PERMISSIONS
)

APP_ROOT=""
KEEP_RELEASES=5
SHARED_DIRS=""
SHARED_FILES=""
HEALTH_CHECK=""
HEALTH_RETRIES=5
HEALTH_DELAY=2
HOOKS_DIR="hooks"
OWNER=""
# Letta da lib/release.sh: analizzando un file per volta shellcheck non la vede.
# shellcheck disable=SC2034
PERMISSIONS=""

ad::config_key_allowed() {
  local candidate="$1" key
  for key in "${AD_CONFIG_KEYS[@]}"; do
    [ "$key" = "$candidate" ] && return 0
  done
  return 1
}

ad::load_config() {
  local file="$1"
  [ -f "$file" ] || ad::die "configurazione non trovata: $file"

  local line number=0 key value
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) ad::die "$file:$number: riga senza '=': $line" ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    # Spazi esterni e una eventuale coppia di virgolette vengono rimossi: il
    # valore utile e' quello che l'utente vede fra le virgolette.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    ad::config_key_allowed "$key" || ad::die "$file:$number: chiave sconosciuta: $key"
    printf -v "$key" '%s' "$value"
  done < "$file"

  [ -n "$APP_ROOT" ] || ad::die "$file: APP_ROOT non impostato"
  case "$KEEP_RELEASES" in
    ''|*[!0-9]*) ad::die "$file: KEEP_RELEASES deve essere un intero" ;;
  esac
  [ "$KEEP_RELEASES" -ge 1 ] || ad::die "$file: KEEP_RELEASES deve essere almeno 1"
  case "$HEALTH_RETRIES" in
    ''|*[!0-9]*) ad::die "$file: HEALTH_RETRIES deve essere un intero" ;;
  esac
}

# ---------------------------------------------------------------------------
# Percorsi
# ---------------------------------------------------------------------------

ad::releases_dir() { printf '%s/releases' "$APP_ROOT"; }
ad::shared_dir() { printf '%s/shared' "$APP_ROOT"; }
ad::current_link() { printf '%s/current' "$APP_ROOT"; }
ad::hooks_path() {
  case "$HOOKS_DIR" in
    /*) printf '%s' "$HOOKS_DIR" ;;
    *) printf '%s/%s' "$APP_ROOT" "$HOOKS_DIR" ;;
  esac
}

ad::current_release() {
  local link
  link="$(ad::current_link)"
  [ -L "$link" ] || return 1
  basename "$(readlink "$link")"
}

# Release ordinate dalla piu' vecchia alla piu' recente. Il nome inizia con un
# timestamp in formato ordinabile, quindi l'ordine alfabetico e' quello reale.
ad::list_releases() {
  local dir entry name
  dir="$(ad::releases_dir)"
  [ -d "$dir" ] || return 0
  # Ciclo sul glob invece di find -printf, che esiste solo nella versione GNU:
  # lo stesso script deve funzionare sul server Linux e sul portatile di chi lo
  # prova in locale.
  for entry in "$dir"/*/; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
      *.incomplete) continue ;;
    esac
    printf '%s\n' "$name"
  done | sort
}

ad::previous_release() {
  local current
  current="$(ad::current_release 2>/dev/null || true)"
  ad::list_releases | grep -vxF "${current:-__nessuna__}" | tail -n 1
}

# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

# mkdir e' atomico su qualunque filesystem POSIX: due deploy avviati insieme non
# possono entrambi crearlo. Il PID salvato serve solo a riconoscere un lock
# rimasto da un processo morto, non a decidere chi ha la precedenza.
ad::lock_acquire() {
  local lock="$APP_ROOT/.deploy.lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s' "$$" > "$lock/pid"
    AD_LOCK_DIR="$lock"
    return 0
  fi

  local owner=""
  [ -f "$lock/pid" ] && owner="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    ad::die "un altro deploy e' in corso (pid $owner)"
  fi

  ad::warn "lock rimasto da un processo terminato (pid ${owner:-sconosciuto}): lo rimuovo"
  rm -rf "$lock"
  mkdir "$lock" || ad::die "impossibile creare il lock $lock"
  printf '%s' "$$" > "$lock/pid"
  AD_LOCK_DIR="$lock"
}

ad::lock_release() {
  [ -n "${AD_LOCK_DIR:-}" ] || return 0
  rm -rf "$AD_LOCK_DIR"
  AD_LOCK_DIR=""
}
