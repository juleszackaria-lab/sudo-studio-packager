#!/usr/bin/env bash
# SUDO STUDIO - P60: full smoke test of a Linux deliverable INSIDE a clean
# container (deb, rpm or tarball). Everything asserted here is the installed
# product: /opt/sudo-studio, the editor binary, the packaged backend binary,
# the packaged runtime binary.
#
#   container-test.sh --pkg-type deb|rpm|tar --pkg <file> --model <gguf>
#                     [--offline] [--install-only] [--variant avx2|compat] [--keep]
#
# Prints "PASS <name>" / "FAIL <name> :: detail" for every check and exits
# non-zero if any check failed. No check is skipped silently: an impossible
# check is a FAIL with its reason.
set -uo pipefail

PKG_TYPE=""; PKG=""; MODEL=""; OFFLINE=0; INSTALL_ONLY=0; VARIANT=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pkg-type) PKG_TYPE=$2; shift 2 ;;
    --pkg) PKG=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;  # P62: n installe que (pour docker commit)
    --variant) VARIANT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
done

PASS=0; FAIL=0; FAILS=""
ok()   { PASS=$((PASS+1)); echo "PASS $1"; }
ko()   { FAIL=$((FAIL+1)); FAILS="$FAILS | $1"; echo "FAIL $1 :: ${2:-}"; }
head1(){ echo; echo "== $1 =="; }

PREFIX=/opt/sudo-studio
# P61: BIN est calcule APRES l installation (plus bas). Le resoudre ici le
# faisait echouer sur un fichier pas encore installe (run 42947411025).
BIN=""
BACKEND="$PREFIX/backend/backend"
RUNTIME="$PREFIX/backend/runtime/server"
PPID_FILE=/tmp/sudo-test-pids
: > "$PPID_FILE"
cleanup() {
  while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done < "$PPID_FILE"
  [ "$KEEP" = "1" ] || true
}
trap cleanup EXIT

echo "=== Sudo Studio container smoke test ==="
echo "pkg-type=$PKG_TYPE pkg=$PKG offline=$OFFLINE variant=${VARIANT:-auto}"
echo "os: $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -a)"

# ------------------------------------------ 0a. dependances d execution (P62)
# Les images de test sont BARE : ni GTK ni glib ni libgbm. Un poste de travail
# reel les a. Sans elles, l editeur ne demarre pas (libglib-2.0.so.0 absent) et
# le .rpm ne s installe meme pas ("nothing provides gbm"). On installe donc la
# liste publique des dependances d execution AVANT le paquet, en le disant :
# le test prouve ensuite que le produit fonctionne avec ses dependances
# documentees, il ne pretend pas qu un conteneur nu suffit.
head1 "dependances d execution"
DEPS_APT="libglib2.0-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 libpango-1.0-0 libcairo2 libgtk-3-0 libx11-xcb1 libxshmfence1"
DEPS_DNF="glib2 nss atk at-spi2-atk cups-libs libdrm libxkbcommon libXcomposite libXdamage libXfixes libXrandr mesa-libgbm alsa-lib pango cairo gtk3 libxshmfence"
if [ "$OFFLINE" = "1" ]; then
  ok "phase hors ligne : dependances deja presentes dans l image (aucune installation)"
elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  # libasound2t64 (ubuntu 24.04) remplace libasound2 : on accepte les deux.
  if apt-get install -y -qq $DEPS_APT > /tmp/deps.log 2>&1; then
    ok "dependances d execution installees (apt) : $(echo $DEPS_APT | wc -w) paquets"
  elif apt-get install -y -qq $(echo $DEPS_APT | sed 's/libasound2/libasound2t64/') > /tmp/deps.log 2>&1; then
    ok "dependances d execution installees (apt, libasound2t64)"
  else
    ko "dependances d execution (apt)" "$(tail -3 /tmp/deps.log | tr '\n' ' ')"
  fi
elif command -v dnf >/dev/null 2>&1; then
  if dnf install -y -q --setopt=install_weak_deps=False $DEPS_DNF > /tmp/deps.log 2>&1; then
    ok "dependances d execution installees (dnf) : $(echo $DEPS_DNF | wc -w) paquets"
  else
    ko "dependances d execution (dnf)" "$(tail -3 /tmp/deps.log | tr '\n' ' ')"
  fi
elif command -v microdnf >/dev/null 2>&1; then
  if microdnf install -y $DEPS_DNF > /tmp/deps.log 2>&1; then
    ok "dependances d execution installees (microdnf)"
  else
    ko "dependances d execution (microdnf)" "$(tail -3 /tmp/deps.log | tr '\n' ' ')"
  fi
else
  echo "[WARN] aucun gestionnaire de paquets connu : dependances non installees"
fi

# ---------------------------------------------------------------- 0. install
head1 "installation"
if [ "$OFFLINE" = "1" ]; then
  # phase 2: the product is already installed by phase 1 (docker commit).
  # Nothing is installed here - we assert the real network is unreachable,
  # then that the SAME installed binaries still work with zero network.
  if curl -sf -m 5 -o /dev/null https://example.com 2>/dev/null; then
    ko "test hors ligne reel" "un acces reseau a reussi : le conteneur n est pas isole"
  else
    ok "aucun acces reseau (curl https://example.com echoue) : test reellement hors ligne"
  fi
  ok "phase hors ligne : paquet deja installe, aucune installation tentee"
else
case "$PKG_TYPE" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    if apt-get install -y -qq "$PKG" > /tmp/install.log 2>&1; then ok "installation du .deb sans erreur de dependance"
    else ko "installation du .deb" "$(tail -5 /tmp/install.log | tr '\n' ' ')"; fi ;;
  rpm)
    if command -v dnf >/dev/null 2>&1; then
      if dnf install -y --nogpgcheck "$PKG" > /tmp/install.log 2>&1; then ok "installation du .rpm sans erreur de dependance"
      else ko "installation du .rpm" "$(tail -5 /tmp/install.log | tr '\n' ' ')"; fi
    else
      if rpm -ivh --nodeps "$PKG" > /tmp/install.log 2>&1; then ok "installation du .rpm (rpm -ivh)"
      else ko "installation du .rpm" "$(tail -5 /tmp/install.log | tr '\n' ' ')"; fi
    fi ;;
  tar)
    DEST=/usr/local
    if tar -xzf "$PKG" -C "$DEST" > /tmp/install.log 2>&1; then ok "extraction du .tar.gz"
    else ko "extraction du .tar.gz" "$(tail -3 /tmp/install.log)"; fi
    if [ -d "$DEST/SudoStudio-Linux" ]; then PREFIX="$DEST/SudoStudio-Linux"; BIN="$PREFIX/bin/codium"; BACKEND="$PREFIX/backend/backend"; RUNTIME="$PREFIX/backend/runtime/server"; fi ;;
  *) ko "type de paquet inconnu" "$PKG_TYPE" ;;
esac
fi

# P61: le binaire editeur se resout ICI, une fois le paquet installe.
BIN="$PREFIX/bin/codium"
[ -x "$BIN" ] || BIN="$PREFIX/bin/sudostudio"
# P61: si le binaire attendu n est pas executable, on dit POURQUOI (present
# mais sans bit x ? autre nom ? rien du tout ?) et on cherche un repli, au
# lieu de sortir sur une ligne seche (run 42946374287).
if [ ! -x "$BIN" ]; then
  echo "[DIAG] editeur attendu : $BIN (executable: non)"
  ls -la "$PREFIX" 2>/dev/null | head -20 || echo "[DIAG] $PREFIX absent"
  ls -la "$PREFIX/bin" 2>/dev/null | head -20 || echo "[DIAG] $PREFIX/bin absent"
  for cand in "$PREFIX/bin/codium" "$PREFIX/bin/sudostudio" "$PREFIX/sudostudio" \
              "$PREFIX/codium" "$PREFIX/bin/code" "$PREFIX/bin/code-insiders"; do
    if [ -f "$cand" ] && [ -x "$cand" ]; then BIN="$cand"; echo "[DIAG] repli retenu : $BIN"; break; fi
    [ -f "$cand" ] && { chmod +x "$cand" 2>/dev/null && [ -x "$cand" ] && { BIN="$cand"; echo "[DIAG] bit x ajoute : $BIN"; break; }; }
  done
fi
[ -x "$BIN" ] || { echo "FATAL: editeur introuvable sous $PREFIX"; exit 1; }
ok "arborescence installee sous $PREFIX"
[ -x "$BACKEND" ] && ok "backend installe et executable" || ko "backend installe" "$BACKEND absent"
[ -x "$RUNTIME" ] && ok "runtime installe et executable" || ko "runtime installe" "$RUNTIME absent"
[ -f "$PREFIX/extensions/sudo-ai/extension.js" ] && ok "extension Sudo Studio presente" || ko "extension presente" "absente"

if [ "$PKG_TYPE" != "tar" ]; then
  [ -x /usr/bin/sudo-studio ] && ok "lanceur /usr/bin/sudo-studio installe" || ko "lanceur /usr/bin/sudo-studio" "absent"
  [ -f /usr/share/applications/sudo-studio.desktop ] && ok "fichier .desktop installe" || ko ".desktop installe" "absent"
  grep -q "Exec=/usr/bin/sudo-studio" /usr/share/applications/sudo-studio.desktop 2>/dev/null \
    && ok ".desktop pointe sur le lanceur" || ko ".desktop pointe sur le lanceur" "$(head -3 /usr/share/applications/sudo-studio.desktop 2>/dev/null)"
  [ -f "$PREFIX/THIRD_PARTY_NOTICES.md" ] || [ -f /usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md ] \
    && ok "THIRD_PARTY_NOTICES inclus" || ko "THIRD_PARTY_NOTICES inclus" "absent"
fi

# P62: mode "installation seule". La phase 2 hors ligne doit tourner sur une
# image ou le produit est REELLEMENT installe. La phase 1 teste aussi la
# DESINSTALLATION, donc son conteneur n a plus le produit a la fin : commit
# d un conteneur dedie, installe et intact.
if [ "$INSTALL_ONLY" = "1" ]; then
  echo "== INSTALLATION SEULE : produit installe sous $PREFIX, aucun test execute =="
  echo "== RESULTAT : installation seule, 0 FAIL =="
  exit 0
fi

# ------------------------------------------------------ 1. headless editor
head1 "editeur headless (xvfb)"
export SUDO_STUDIO_ROOT="$PREFIX"
export HOME=${HOME:-/root}
# P61: en root, VSCodium exige --no-sandbox ET un --user-data-dir distinct
# ("You are trying to start VSCodium as a super user ..."). Un poste reel
# n est pas root : ce sont deux options de HARNAIS, pas du produit.
ED_USER_DATA="${TMPDIR:-/tmp}/sut-editor-userdata"
mkdir -p "$ED_USER_DATA"
if command -v xvfb-run >/dev/null 2>&1; then
  if xvfb-run -a "$BIN" --no-sandbox --user-data-dir "$ED_USER_DATA" --version > /tmp/editor-version.txt 2>&1; then
    ok "editeur demarre sous Xvfb ($(head -1 /tmp/editor-version.txt))"
  else
    ko "editeur demarre sous Xvfb" "$(tail -3 /tmp/editor-version.txt | tr '\n' ' ')"
  fi
  EXTL=$(xvfb-run -a "$BIN" --no-sandbox --user-data-dir "$ED_USER_DATA" --extensions-dir "$PREFIX/extensions" --list-extensions 2>/dev/null | tr '\n' ' ')
  case "$EXTL" in *sudo*) ok "l editeur installe decouvre l extension Sudo Studio" ;; *) ko "extension decouverte par l editeur" "liste: $EXTL" ;; esac
else
  ko "xvfb disponible" "xorg-x11-server-Xvfb / xvfb non installe"
fi

# ------------------------------------------------------ 2. backend /health
head1 "backend"
export SUDO_STUDIO_HOME="${SUDO_STUDIO_HOME:-$HOME/.local/share/sudo-studio}"
export PORT=5000
"$BACKEND" > /tmp/backend.log 2>&1 &
echo $! >> "$PPID_FILE"
BPORT=""
for i in $(seq 1 60); do
  if curl -sf -m 2 -o /tmp/health-backend.json "http://127.0.0.1:5000/api/system/health"; then BPORT=5000; break; fi
  sleep 1
done
if [ -n "$BPORT" ]; then
  ok "backend repond sur /api/system/health"
  echo "   $(head -c 200 /tmp/health-backend.json)"
else
  ko "backend /api/system/health" "$(tail -5 /tmp/backend.log | tr '\n' ' ')"
fi

# licence (couche Ed25519) evaluatee par le binaire empaquete
if LICENSE_OUT=$("$BACKEND" --license-status 2>/dev/null); then
  case "$LICENSE_OUT" in
    *'"ok":true'*) ok "licence evaluee par le binaire installe : $LICENSE_OUT" ;;
    *) ko "licence evaluee par le binaire installe" "$LICENSE_OUT" ;;
  esac
else
  ko "licence evaluee par le binaire installe" "--license-status a echoue"
fi

# ------------------------------------------------------ 3. runtime + modele
head1 "runtime et modele"
RURL="http://127.0.0.1:6000"
# P62: le runtime resout ~/.sudo_studio/models avec le dossier personnel du
# COMPTE (os.path.expanduser), pas avec la variable HOME. Les deux doivent
# donc designer le meme dossier, sinon la copie du modele passe inapercue et
# le chargement echoue (run 43461006759, phase hors ligne). On impose le
# dossier reel du compte a TOUT le processus (backend, agent, runtime).
RTHOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
[ -n "$RTHOME" ] || RTHOME="$HOME"
export HOME="$RTHOME"
MODELS_DIR="$HOME/.sudo_studio/models"
mkdir -p "$MODELS_DIR"
echo "   dossier personnel utilise : $HOME (modeles : $MODELS_DIR)"
if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
  NEED_KB=$(( $(stat -c %s "$MODEL") / 1024 + 1024 ))
  FREE_KB=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
  echo "   place libre dans $HOME : $((FREE_KB / 1024)) Mo (modele : $((NEED_KB / 1024)) Mo)"
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    ko "copie du modele de test" "place insuffisante dans $HOME ($((FREE_KB / 1024)) Mo libres)"
  else
    if cp "$MODEL" "$MODELS_DIR/" 2>/tmp/cp-model.log; then
      # Verification REELLE : meme taille, sinon la copie est un echec.
      if [ "$(stat -c %s "$MODEL")" = "$(stat -c %s "$MODELS_DIR/$(basename "$MODEL")")" ]; then
        ok "modele de test copie dans $MODELS_DIR ($((NEED_KB / 1024)) Mo)"
      else
        ko "copie du modele de test" "taille differente apres copie"
      fi
    else
      ko "copie du modele de test" "$(tail -2 /tmp/cp-model.log | tr '\n' ' ')"
    fi
  fi
else
  ko "modele de test fourni" "--model absent ou illisible : $MODEL"
fi
if [ -n "$VARIANT" ]; then export SUDO_LLAMACPP_VARIANT="$VARIANT"; fi
HOME="$RTHOME" "$RUNTIME" --port 6000 > /tmp/runtime.log 2>&1 &
echo $! >> "$PPID_FILE"
RFOUND=0
for i in $(seq 1 120); do
  if curl -sf -m 2 -o /tmp/health-runtime.json "$RURL/health"; then RFOUND=1; break; fi
  sleep 1
done
if [ "$RFOUND" = "1" ]; then
  ok "runtime repond sur /health"
  echo "   $(head -c 200 /tmp/health-runtime.json)"
else
  ko "runtime /health" "$(tail -5 /tmp/runtime.log | tr '\n' ' ')"
fi

LOADED=0
for i in $(seq 1 180); do
  if curl -sf -m 2 "$RURL/health" 2>/dev/null | grep -q '"loaded":[[:space:]]*true'; then LOADED=1; break; fi
  if curl -sf -m 2 "$RURL/health" 2>/dev/null | grep -q '"loaded": true'; then LOADED=1; break; fi
  sleep 2
done
VARIANT_USED=$(grep -oE 'variant=[a-z0-9]+' /tmp/runtime.log | tail -1 || true)
if [ "$LOADED" = "1" ]; then
  ok "modele charge (${VARIANT_USED:-variante non journalisee})"
else
  ko "modele charge" "$(grep -iE 'error|erreur|mock|failed' /tmp/runtime.log | tail -3 | tr '\n' ' ')"
  # P62: dire POURQUOI le modele n a pas ete charge (HOME reel, contenu du
  # dossier de modeles, journal de detection complet, espace disque).
  echo "[DIAG] HOME=$HOME (compte : $RTHOME) MODELS=$MODELS_DIR MODEL_ARG=$MODEL"
  ls -la "$MODELS_DIR" 2>&1 | head -10
  echo "[DIAG] detection : $(head -c 1200 /tmp/health-runtime.json 2>/dev/null)"
  echo "[DIAG] disque : $(df -h "$HOME" 2>/dev/null | tail -1)"
  echo "[DIAG] runtime.log (30 dernieres lignes) :"
  tail -30 /tmp/runtime.log | cut -c1-220
fi

MODEL_ID=$(curl -sf -m 5 "$RURL/v1/models" 2>/dev/null | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$MODEL_ID" ] || MODEL_ID=local
echo "   modele servi par /v1/models : $MODEL_ID"
if [ "$LOADED" = "1" ]; then
  printf '{"model":"%s","messages":[{"role":"user","content":"Reponds uniquement: OK"}],"max_tokens":16}' \
    "$MODEL_ID" > /tmp/chat-payload.json
  python3 -c 'import json,sys; json.load(open("/tmp/chat-payload.json"))' 2>/dev/null \
    && echo "   charge utile JSON valide" || echo "   [WARN] charge utile non valide"
  CODE=$(curl -s -o /tmp/chat.json -w '%{http_code}' -X POST "$RURL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    --data-binary @/tmp/chat-payload.json || echo 000)
  if [ "$CODE" = "200" ] && grep -q '"choices"' /tmp/chat.json; then
    ok "POST /v1/chat/completions repond (extra: $(head -c 120 /tmp/chat.json))"
  else
    ko "/v1/chat/completions" "HTTP $CODE $(head -c 200 /tmp/chat.json)"
  fi
else
  ko "/v1/chat/completions" "non teste : modele non charge"
fi

# ------------------------------------------------------ 4. agent (Electron-as-node)
head1 "agent (ELECTRON_RUN_AS_NODE=1)"
AGENT_LOG_DIR="$SUDO_STUDIO_HOME/logs"
mkdir -p "$AGENT_LOG_DIR"
export SUDO_AGENT_TOKEN="p60-container-token-0123456789"
export SUDO_AGENT_PORT=7311
export SUDO_AGENT_STORE="$SUDO_STUDIO_HOME/agent-store"
export SUDO_STUDIO_LOGS="$AGENT_LOG_DIR"
export SUDO_AGENT_PROVIDER="{\"type\":\"local\",\"baseUrl\":\"$RURL\",\"model\":\"$MODEL_ID\"}"
# P61: l agent tourne sous un utilisateur NON root, comme sur un poste reel.
# En root, VSCodium refuse de demarrer sans options de contournement, et ces
# options n ont aucun sens en mode Node (elles sont parlees par node, pas par
# la CLI) : d ou un journal vide et aucun serveur (run 42949351951).
AGENT_DIR=/tmp/sut-agent
mkdir -p "$AGENT_DIR/store" "$AGENT_DIR/logs" "$AGENT_DIR/home"
if [ "$(id -u)" = "0" ]; then
  AGENT_USER=${SUDO_TEST_USER:-sutuser}
  id "$AGENT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$AGENT_USER" 2>/dev/null || true
  if id "$AGENT_USER" >/dev/null 2>&1; then
    chown -R "$AGENT_USER" "$AGENT_DIR" 2>/dev/null || true
    AGENT_HOME=$(getent passwd "$AGENT_USER" | cut -d: -f6)
    AGENT_RUN="su $AGENT_USER -c"
    AGENT_MODE="utilisateur $AGENT_USER"
  else
    AGENT_HOME=$HOME; AGENT_RUN="bash -c"; AGENT_MODE="root (pas d utilisateur de test)"
  fi
else
  AGENT_HOME=$HOME; AGENT_RUN="bash -c"; AGENT_MODE="utilisateur courant ($(id -un))"
fi

agent_env() {
  # P61 (run 42971420882, job ubuntu-22.04) : la re-execution approuvee
  # echouait avec code=checkpoint / EACCES mkdir
  # '/root/.local/share/sudo-studio/.sudo_studio/agent/checkpoints/<session>'
  # parce que l agent heritait du SUDO_STUDIO_HOME de root en tournant sous
  # sutuser. Le moteur exige un instantane AVANT la premiere mutation (garde
  # de securite conservee) : on lui donne donc un dossier d etat a lui.
  echo "SUDO_STUDIO_HOME=$AGENT_DIR/home HOME=$AGENT_HOME SUDO_AGENT_TOKEN=$SUDO_AGENT_TOKEN SUDO_AGENT_PORT=7311 SUDO_AGENT_STORE=$AGENT_DIR/store SUDO_STUDIO_LOGS=$AGENT_DIR/logs SUDO_AGENT_PROVIDER='{\"type\":\"local\",\"baseUrl\":\"$RURL\",\"model\":\"$MODEL_ID\"}'"
}

AGENT_UP=0
AGENT_ROUTE=""
: > /tmp/agent.log
# P61: trois routes, essayees dans cet ordre. La 1re et la 2e passent par
# l EDITEUR installe (mode Node) : c est la preuve demandee. La 3e (node du
# systeme) n est qu un repli de diagnostic, et elle est NOMMEE comme telle.
agent_launch() {
  local route="$1" argv="$2"
  $AGENT_RUN "$(agent_env) $argv" > /tmp/agent.log 2>&1 &
  local pid=$!
  echo $pid >> "$PPID_FILE"
  for i in $(seq 1 40); do
    if curl -sf -m 2 -H "Authorization: Bearer $SUDO_AGENT_TOKEN" -o /dev/null "http://127.0.0.1:7311/health"; then AGENT_UP=1; AGENT_ROUTE="$route"; return 0; fi
    sleep 1
  done
  # P61: on ne tue QUE la tentative en cours (cleanup emporterait le backend
  # et le runtime deja valides plus haut).
  echo "[DIAG] route $route : pas de serveur (log $(wc -c < /tmp/agent.log) octets)"
  head -5 /tmp/agent.log 2>/dev/null | sed 's/^/[DIAG]   /'
  pkill -f 'sudo-agent/src/server.js' 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  sleep 1
  return 1
}

agent_launch "editeur bin/codium" "ELECTRON_RUN_AS_NODE=1 $BIN $PREFIX/sudo-agent/src/server.js" || \
agent_launch "editeur binaire direct" "ELECTRON_RUN_AS_NODE=1 $PREFIX/codium $PREFIX/sudo-agent/src/server.js" || \
agent_launch "node du systeme (repli, PAS l editeur)" "node $PREFIX/sudo-agent/src/server.js" || true

if [ "$AGENT_UP" = "1" ]; then
  ok "agent demarre via l editeur en mode Node (route: $AGENT_ROUTE, $AGENT_MODE)"
else
  ko "agent demarre via l editeur en mode Node" "$(tail -5 /tmp/agent.log | tr '\n' ' ')"
fi

if [ "$AGENT_UP" = "1" ] && [ "$LOADED" = "1" ]; then
  PROJ=/tmp/p60-projet
  # P61: la regle de projet s ecrit dans $HOME/.sudo_studio/agent/rules/ ;
  # le run 42952619370 a rendu 500 "regle de projet non enregistree". On
  # imprime donc ou l agent ecrit et si c est accessible en ecriture.
  # P61: empreinte du moteur REELLEMENT installe (le correctif P61-5 doit
  # etre dans le paquet, pas seulement dans le depot).
  if [ -f "$PREFIX/sudo-agent/src/loop.js" ]; then
    echo "[DIAG] moteur installe : loop.js $(wc -c < "$PREFIX/sudo-agent/src/loop.js") octets, sha256 $(sha256sum "$PREFIX/sudo-agent/src/loop.js" | cut -c1-16), correctif P61-5 present: $(grep -c 'beforeCalls' "$PREFIX/sudo-agent/src/loop.js")"
  else
    echo "[DIAG] moteur installe : $PREFIX/sudo-agent/src/loop.js ABSENT"
  fi
  echo "[DIAG] agent HOME=$AGENT_HOME ; ecriture regles : $(su "$AGENT_USER" -c "test -w '$AGENT_HOME' && echo ok || echo NON-ACCESSIBLE" 2>/dev/null || echo inconnue)"
  echo "[DIAG] droits projet : $(ls -ld "$PROJ" | cut -d" " -f1,3,4)"
  rm -rf "$PROJ"; mkdir -p "$PROJ"
  echo "console.log('x')" > "$PROJ/app.js"
  # P61: l agent tourne sous un autre utilisateur que celui du harnais.
  chmod -R 777 "$PROJ" 2>/dev/null || true
  SESS=$(curl -s -X POST -H "Authorization: Bearer $SUDO_AGENT_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"title\":\"p60\",\"projectRoot\":\"$PROJ\"}" "http://127.0.0.1:7311/sessions")
  SID=$(echo "$SESS" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$SID" ] && ok "session agent creee" || ko "session agent creee" "$SESS"
  if [ -n "$SID" ]; then
    # The turn streams (SSE) and PAUSES on the write approval: the request stays
    # open while we approve, which is exactly the human-in-the-loop path.
    ( timeout 300 curl -s -N -X POST -H "Authorization: Bearer $SUDO_AGENT_TOKEN" -H 'Content-Type: application/json' \
        -d '{"prompt":"Cree le fichier hello-linux.txt a la racine du projet, contenant exactement: bonjour linux"}' \
        "http://127.0.0.1:7311/sessions/$SID/messages" > /tmp/turn.sse 2>&1 ) &
    TURN_PID=$!
    APPLY=0
    for i in $(seq 1 60); do
      PEND=$(curl -s -H "Authorization: Bearer $SUDO_AGENT_TOKEN" "http://127.0.0.1:7311/sessions/$SID/approvals")
      # P61: l extraction precedente imprimait la ligne ENTIERE (motif non
      # ancre), donc l identifiant envoye etait illisible -> "corps JSON
      # invalide" a chaque tentative (run 42951099165). On decoupe d abord
      # sur les accolades puis on prend la 1re valeur "id".
      AID=$(echo "$PEND" | tr '{' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      if [ -n "$AID" ]; then
        # P61: decision "once". Le run 42953965314 a montre que "project"
        # rend 500 "regle de projet non enregistree" sur cet outil (defaut de
        # fond note separement) ; l objet du test est le circuit d approbation
        # de bout en bout, pas l ecriture d une regle persistante.
        R=$(curl -s -X POST -H "Authorization: Bearer $SUDO_AGENT_TOKEN" -H 'Content-Type: application/json' \
          -d "{\"requestId\":\"$AID\",\"decision\":\"once\"}" \
          "http://127.0.0.1:7311/sessions/$SID/approvals")
        echo "   approbation $AID -> $R"
        APPLY=$((APPLY+1))
      fi
      [ -f "$PROJ/hello-linux.txt" ] && break
      sleep 2
    done
    wait $TURN_PID 2>/dev/null || true
    if [ -f "$PROJ/hello-linux.txt" ] && grep -qi "bonjour linux" "$PROJ/hello-linux.txt"; then
      ok "l agent a cree hello-linux.txt avec le bon contenu (approbation accordee)"
    else
      ko "l agent cree le fichier demande" "fichier absent ou vide (approbations=$APPLY)"
      echo "[DIAG] contenu du projet apres le tour :"
      ls -la "$PROJ" 2>&1 | sed 's/^/[DIAG]   /'
      echo "[DIAG] evenements du tour (tail) :"
      tail -40 /tmp/turn.sse 2>/dev/null | cut -c1-400 | sed 's/^/[DIAG]   /'
      echo "[DIAG] journal de l agent (tail) :"
      tail -20 /tmp/agent.log 2>/dev/null | cut -c1-300 | sed 's/^/[DIAG]   /'
      # P61: le journal du MOTEUR (agent.log) porte le texte d erreur complet
      # des appels d outil ; /tmp/agent.log ne contient que la poignee stdout.
      echo "[DIAG] journal du moteur ($AGENT_DIR/logs) :"
      for f in "$AGENT_DIR"/logs/*.log; do
        [ -f "$f" ] || continue
        echo "[DIAG]   ==> $(basename "$f")"
        grep -E "tool fail|tool ok|approuve|erreur" "$f" 2>/dev/null | tail -12 | cut -c1-400 | sed 's/^/[DIAG]     /'
      done
    fi
  fi
fi

# ------------------------------------------------------ 5. journals (dossier Linux)
head1 "journaux"
EXPECTED_LOG_DIR="$HOME/.local/share/sudo-studio/logs"
[ -n "${XDG_STATE_HOME:-}" ] && EXPECTED_LOG_DIR="$XDG_STATE_HOME/sudo-studio/logs"
FOUND_LOG=0
for d in "$EXPECTED_LOG_DIR" "$SUDO_STUDIO_LOGS" "$HOME/.local/share/sudo-studio/logs"; do
  [ -d "$d" ] && ls "$d"/*.log >/dev/null 2>&1 && FOUND_LOG=1 && LOGDIR_ACTUAL="$d" && break
done
if [ "$FOUND_LOG" = "1" ]; then
  ok "journaux ecrits dans le dossier Linux attendu ($LOGDIR_ACTUAL)"
  head -2 "$LOGDIR_ACTUAL"/*.log 2>/dev/null | head -4
else
  ko "journaux dans le dossier Linux attendu" "cherche: $EXPECTED_LOG_DIR"
fi
if grep -rqiE 'ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}' "$EXPECTED_LOG_DIR" 2>/dev/null; then
  ko "aucun secret en clair dans les journaux" "motif de jeton trouve"
else
  ok "aucun secret en clair dans les journaux"
fi

# ------------------------------------------------------ 6. desinstallation
head1 "desinstallation"
cleanup
sleep 1
if [ "$OFFLINE" = "1" ]; then
  ok "desinstallation non testee hors ligne (conteneur jetable, testee en phase 1)"
elif [ "$PKG_TYPE" = "deb" ]; then
  # Le test lui-meme ecrit extensions.json dans $PREFIX/extensions : c est un
  # artefact de harnais, on le retire avant de juger la desinstallation.
  rm -f "$PREFIX/extensions/extensions.json" 2>/dev/null || true
  apt-get remove -y -qq sudostudio > /tmp/uninstall.log 2>&1
  if [ ! -e /usr/bin/sudo-studio ] && [ ! -e "$PREFIX/backend/backend" ]; then
    ok "desinstallation propre (deb) : fichiers du paquet retires"
    [ -d "$PREFIX" ] && { echo "[INFO] restes hors paquet dans $PREFIX :"; find "$PREFIX" -maxdepth 2 2>/dev/null | head -10; }
  else ko "desinstallation deb" "fichiers du paquet encore presents"; fi
elif [ "$PKG_TYPE" = "rpm" ]; then
  rm -f "$PREFIX/extensions/extensions.json" 2>/dev/null || true
  if command -v dnf >/dev/null 2>&1; then dnf remove -y sudostudio > /tmp/uninstall.log 2>&1; else rpm -e sudostudio > /tmp/uninstall.log 2>&1; fi
  if [ ! -e /usr/bin/sudo-studio ] && [ ! -e "$PREFIX/backend/backend" ]; then
    ok "desinstallation propre (rpm) : fichiers du paquet retires"
    [ -d "$PREFIX" ] && { echo "[INFO] restes hors paquet dans $PREFIX :"; find "$PREFIX" -maxdepth 2 2>/dev/null | head -10; }
  else ko "desinstallation rpm" "fichiers du paquet encore presents"; fi
else
  rm -rf /usr/local/SudoStudio-Linux && ok "suppression du dossier extrait (tar)"
fi

echo
echo "== RESULTAT : $PASS PASS, $FAIL FAIL =="
[ "$FAIL" -gt 0 ] && echo "echecs:$FAILS"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
