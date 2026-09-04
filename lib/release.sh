# shellcheck shell=bash
# Creazione, attivazione, rollback e potatura delle release.

ad::init_tree() {
  mkdir -p "$(ad::releases_dir)" "$(ad::shared_dir)" "$(ad::hooks_path)"

  # Lo script gira con IFS ristretto a newline e tab per proteggere i percorsi
  # con spazi: qui serve invece lo spazio come separatore, perche' gli elenchi
  # di percorsi condivisi si scrivono su una riga sola.
  local entry
  local IFS=' '
  for entry in $SHARED_DIRS; do
    mkdir -p "$(ad::shared_dir)/$entry"
  done
  for entry in $SHARED_FILES; do
    mkdir -p "$(dirname "$(ad::shared_dir)/$entry")"
    [ -e "$(ad::shared_dir)/$entry" ] || : > "$(ad::shared_dir)/$entry"
  done
}

ad::new_release_name() {
  local stamp suffix=""
  stamp="$(date -u +%Y%m%dT%H%M%S)"
  if [ -n "${AD_REVISION:-}" ]; then
    suffix="-${AD_REVISION}"
  elif command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
    suffix="-$(git rev-parse --short HEAD)"
  fi
  printf '%s%s' "$stamp" "$suffix"
}

# Il contenuto viene montato in una cartella con suffisso .incomplete e
# rinominato solo alla fine: una estrazione interrotta a meta' non deve mai
# diventare una release che qualcuno puo' attivare o su cui puo' tornare.
ad::stage_release() {
  local name="$1" source="$2" kind="$3"
  local releases staging final
  releases="$(ad::releases_dir)"
  staging="$releases/$name.incomplete"
  final="$releases/$name"

  [ -e "$final" ] && ad::die "la release $name esiste gia'"
  rm -rf "$staging"
  mkdir -p "$staging"

  case "$kind" in
    dir)
      [ -d "$source" ] || ad::die "cartella sorgente non trovata: $source"
      # Il punto finale su cp -a copia anche i file nascosti, che con "$source"/*
      # resterebbero fuori portando in produzione un albero incompleto.
      cp -a "$source/." "$staging/" || { rm -rf "$staging"; ad::die "copia fallita da $source"; }
      ;;
    archive)
      [ -f "$source" ] || ad::die "archivio non trovato: $source"
      tar -xf "$source" -C "$staging" || { rm -rf "$staging"; ad::die "estrazione fallita di $source"; }
      ;;
    *)
      rm -rf "$staging"
      ad::die "tipo di sorgente sconosciuto: $kind"
      ;;
  esac

  ad::link_shared "$staging"
  ad::apply_ownership "$staging"

  mv "$staging" "$final" || { rm -rf "$staging"; ad::die "impossibile completare la release $name"; }
  printf '%s' "$final"
}

# I percorsi condivisi vivono fuori dalla release: sopravvivono ai deploy e
# restano gli stessi per tutte le versioni attive o passate.
ad::link_shared() {
  local release="$1" entry target
  local IFS=' '
  for entry in $SHARED_DIRS; do
    target="$(ad::shared_dir)/$entry"
    mkdir -p "$target"
    rm -rf "${release:?}/$entry"
    mkdir -p "$(dirname "$release/$entry")"
    ln -s "$target" "$release/$entry" || ad::die "collegamento fallito per la cartella condivisa $entry"
  done
  for entry in $SHARED_FILES; do
    target="$(ad::shared_dir)/$entry"
    mkdir -p "$(dirname "$target")"
    [ -e "$target" ] || : > "$target"
    rm -f "${release:?}/$entry"
    mkdir -p "$(dirname "$release/$entry")"
    ln -s "$target" "$release/$entry" || ad::die "collegamento fallito per il file condiviso $entry"
  done
}

ad::apply_ownership() {
  local path="$1"
  if [ -n "$OWNER" ]; then
    chown -R "$OWNER" "$path" 2>/dev/null || ad::warn "chown a $OWNER non riuscito: servono privilegi"
  fi
  if [ -n "$PERMISSIONS" ]; then
    chmod -R "$PERMISSIONS" "$path" 2>/dev/null || ad::warn "chmod a $PERMISSIONS non riuscito"
  fi
}

# Sostituzione atomica del collegamento.
#
# `ln -sfn` cancella e ricrea: fra le due operazioni esiste un istante in cui
# `current` non punta a niente, e una richiesta che arriva in quel momento vede
# un 404. Creare il collegamento con un nome temporaneo e rinominarlo con
# `mv -T` usa invece rename(2), che sostituisce il collegamento in un colpo solo.
ad::activate() {
  local release_path="$1"
  local link staging
  link="$(ad::current_link)"
  staging="$APP_ROOT/.current.$$"

  ln -s "$release_path" "$staging" || ad::die "impossibile creare il collegamento temporaneo"
  if ! mv -T "$staging" "$link" 2>/dev/null; then
    rm -f "$staging"
    ad::die "sostituzione atomica non riuscita: mv -T non supportato su questo sistema"
  fi
}

ad::run_health_check() {
  [ -n "$HEALTH_CHECK" ] || return 0

  local attempt=1
  while [ "$attempt" -le "$HEALTH_RETRIES" ]; do
    if ( cd "$(ad::current_link)" && eval "$HEALTH_CHECK" ) >/dev/null 2>&1; then
      ad::ok "controllo di salute superato al tentativo $attempt"
      return 0
    fi
    if [ "$attempt" -lt "$HEALTH_RETRIES" ]; then
      ad::log "controllo di salute fallito, nuovo tentativo fra ${HEALTH_DELAY}s ($attempt/$HEALTH_RETRIES)"
      sleep "$HEALTH_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

ad::prune() {
  local keep="$1"
  local current previous releases total index=0 name
  current="$(ad::current_release 2>/dev/null || true)"
  previous="$(ad::previous_release 2>/dev/null || true)"

  releases="$(ad::list_releases)"
  [ -n "$releases" ] || return 0
  total="$(printf '%s\n' "$releases" | wc -l | tr -d ' ')"
  [ "$total" -gt "$keep" ] || return 0

  local to_remove=$((total - keep))
  while IFS= read -r name; do
    [ "$index" -lt "$to_remove" ] || break
    # La release attiva e quella precedente non si toccano mai: la seconda e'
    # l'unica destinazione garantita di un rollback immediato.
    if [ "$name" = "$current" ] || [ "$name" = "$previous" ]; then
      continue
    fi
    rm -rf "${APP_ROOT:?}/releases/$name"
    ad::log "rimossa la release $name"
    index=$((index + 1))
  done <<< "$releases"
}

ad::cleanup_incomplete() {
  local dir entry
  dir="$(ad::releases_dir)"
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*.incomplete; do
    [ -e "$entry" ] || continue
    ad::warn "rimuovo una release incompleta rimasta da un tentativo precedente: $(basename "$entry")"
    rm -rf "$entry"
  done
}
