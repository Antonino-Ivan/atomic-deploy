# shellcheck shell=bash
# Esecuzione degli hook definiti dall'applicazione.

# Gli hook ricevono il contesto in variabili d'ambiente invece che in argomenti
# posizionali: un hook scritto oggi continua a funzionare se domani il contesto
# si arricchisce di un altro valore.
ad::run_hook() {
  local name="$1" release_path="$2"
  local script
  script="$(ad::hooks_path)/$name"

  [ -f "$script" ] || return 0
  if [ ! -x "$script" ]; then
    ad::warn "hook $name presente ma non eseguibile: lo salto (chmod +x per attivarlo)"
    return 0
  fi

  ad::log "hook $name"
  local previous
  previous="$(ad::previous_release 2>/dev/null || true)"

  if ! AD_APP_ROOT="$APP_ROOT" \
    AD_RELEASE_PATH="$release_path" \
    AD_RELEASE_NAME="$(basename "$release_path")" \
    AD_PREVIOUS_RELEASE="$previous" \
    AD_SHARED_DIR="$(ad::shared_dir)" \
    AD_CURRENT_LINK="$(ad::current_link)" \
    AD_HOOK="$name" \
    "$script"; then
    return 1
  fi
  return 0
}
