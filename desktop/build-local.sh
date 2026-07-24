#!/usr/bin/env bash
# build-local.sh — Build LOCAL do FrankMD Desktop no macOS e Linux (sem CI).
# Empacota o app nativo (Tauri 2) que roda o container do FrankMD numa janela
# própria. Mesmo padrão do ShvIA/SHVTERM build-local.sh.
#   macOS  -> .dmg + .app
#   Linux  -> .deb + .AppImage   (targets do desktop/src-tauri/tauri.conf.json)
#
# PRÉ-REQUISITOS (instalar uma vez):
#   Comum:   Node 20+, Rust (rustup default stable), Docker (runtime do app)
#   macOS:   xcode-select --install
#   Linux (Debian/Ubuntu):
#     sudo apt-get install -y libwebkit2gtk-4.1-dev build-essential curl wget file \
#       libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf
#   Linux (Arch/Omarchy):
#     sudo pacman -S --needed webkit2gtk-4.1 base-devel curl wget file openssl \
#       gtk3 libayatana-appindicator librsvg patchelf
#
# USO (na pasta desktop/):
#   ./build-local.sh                 # build normal (todos os targets do SO)
#   ./build-local.sh --skip-npm      # pula 'npm install' (tauri CLI já presente)
#   ./build-local.sh --bundles deb   # só um target (deb|appimage|dmg|app)
#   ./build-local.sh --no-sign       # (macOS) NÃO assina/notariza — build de teste
#   ./build-local.sh --skip-git-pull # NÃO sincroniza com o remoto antes do build
#
# VERSÃO (padrão da casa): a versão sai de ../version.md (a versão do fork). Antes
# do build, ela é gravada em tauri.conf.json e Cargo.toml, pra o app e o instalador
# saírem com a versão certa. Se ../version.md não existir (branch isolada do app),
# o passo é pulado e vale o que já está no tauri.conf.json.
#
# GIT PULL (padrão da casa): antes de tudo, 'git pull --ff-only' pra não empacotar
# código velho. É fast-forward-only (nunca cria merge) e NÃO trava o build se
# falhar (offline / mudanças locais / branch divergente) — avisa e segue com o
# local. Pule com --skip-git-pull.
#
# ASSINATURA (macOS): sem assinar, o macOS trata o app baixado como "danificado"
# (quarentena) e oferece MOVER PARA A LIXEIRA. Este script assina com o cert
# **Developer ID Application** do keychain e o `tauri build` notariza+staple sozinho
# quando há credencial. A senha de app (Apple ID) fica no keychain (serviço
# "frankmd-notarize"), NUNCA no repo. Guardar uma vez:
#   security add-generic-password -U -s frankmd-notarize -a SEU_APPLE_ID -w
# Sem cert -> build sai sem assinar; sem credencial -> assina mas não notariza.
#
# Saída: desktop/src-tauri/target/release/bundle/
# Obs.: o 1º build compila o Rust inteiro (~minutos); os próximos são incrementais.
set -euo pipefail
cd "$(dirname "$0")"

# ── Cronômetro do build: tempo total (parede) + por etapa ───────────────────
SECONDS=0
_BUILD_OS=$(uname -s); [ "$_BUILD_OS" = Darwin ] && _BUILD_OS=macOS
_PH_NAMES=(); _PH_TIMES=(); _PH_CUR=""; _PH_START=0
_fmt() {  # $1 = segundos -> "1h 02m 03s" / "4m 05s" / "37s"
  local t=$1
  if   [ "$t" -ge 3600 ]; then printf '%dh %02dm %02ds' $((t/3600)) $(((t%3600)/60)) $((t%60))
  elif [ "$t" -ge 60 ];   then printf '%dm %02ds' $((t/60)) $((t%60))
  else                         printf '%ds' "$t"; fi
}
step() {  # fecha a etapa anterior, abre a nova, e mostra o relógio corrente
  local now=$SECONDS
  if [ -n "$_PH_CUR" ]; then
    _PH_NAMES+=("$_PH_CUR"); _PH_TIMES+=($((now - _PH_START)))
  elif [ "$now" -gt 0 ]; then
    _PH_NAMES+=("preparação"); _PH_TIMES+=("$now")
  fi
  _PH_CUR="$1"; _PH_START=$now
  echo "==> [$(_fmt "$now")] $1"
}
_summary() {  # tabela final: cada etapa + TOTAL
  if [ -n "$_PH_CUR" ]; then
    _PH_NAMES+=("$_PH_CUR"); _PH_TIMES+=($((SECONDS - _PH_START))); _PH_CUR=""
  fi
  echo ""
  echo "⏱  tempo por etapa ($_BUILD_OS):"
  local i
  for i in "${!_PH_NAMES[@]}"; do
    printf '     %8s  %s\n' "$(_fmt "${_PH_TIMES[$i]}")" "${_PH_NAMES[$i]}"
  done
  echo "     ────────"
  printf '     %8s  TOTAL\n' "$(_fmt "$SECONDS")"
}
_on_exit() {  # se abortar (exit != 0), ainda mostra quanto tempo rodou
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "" >&2
    echo "❌ build abortou após $(_fmt "$SECONDS")  ($_BUILD_OS, exit $code)" >&2
  fi
}
trap _on_exit EXIT

usage() { awk 'NR>1{ if($0=="set -euo pipefail") exit; sub(/^# ?/,""); print }' "$0"; }

# ── git pull antes do build (padrão da casa) ────────────────────────────────
git_sync() {
  if [ "${SKIP_GIT_PULL:-0}" -eq 1 ]; then echo "    (pulado: --skip-git-pull)"; return 0; fi
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "    (não é um clone git — pulando)"; return 0
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "    (sem remote 'origin' — pulando)"; return 0
  fi
  echo "    branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') — git pull --ff-only"
  local out
  if out="$(git pull --ff-only 2>&1)"; then
    echo "$out" | sed 's/^/    /'
  else
    echo "$out" | sed 's/^/    /' >&2
    echo "    ⚠️  git pull não aplicou (offline, mudanças locais, ou branch divergente)." >&2
    echo "        O build vai continuar com o código LOCAL atual." >&2
  fi
}

# ── Preflight: checa o toolchain ANTES dos passos lentos ────────────────────
preflight() {
  local missing=()

  command -v node >/dev/null 2>&1 || missing+=(
    "Node.js não encontrado. Instale o Node 20+ (https://nodejs.org, 'brew install node' ou nvm)."
  )
  command -v npm >/dev/null 2>&1 || missing+=("npm não encontrado (vem com o Node).")

  # Rust: recupera o cargo de ~/.cargo/bin se instalado mas fora do PATH.
  if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "    (cargo achado em ~/.cargo/bin — adicionado ao PATH desta execução)"
  fi
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
    missing+=(
"Rust (cargo) não encontrado — é o que o Tauri usa pra compilar.
       Instale:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
       Depois:   source \"\$HOME/.cargo/env\"   (ou reabra o terminal)"
    )
  fi

  # macOS: clang/linker vêm do Command Line Tools do Xcode.
  if [ "$_BUILD_OS" = macOS ] && ! xcode-select -p >/dev/null 2>&1; then
    missing+=("Command Line Tools do Xcode ausentes (clang/linker).
       Instale:  xcode-select --install")
  fi

  # Linux: WebKitGTK dev é obrigatório pro WebView do Tauri.
  if [ "$_BUILD_OS" = Linux ] && command -v pkg-config >/dev/null 2>&1 \
     && ! pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
    missing+=(
"libwebkit2gtk-4.1-dev ausente (e outras deps do Tauri no Linux). Instale:
       Debian/Ubuntu: sudo apt-get install -y libwebkit2gtk-4.1-dev build-essential \\
         curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf
       Arch/Omarchy:  sudo pacman -S --needed webkit2gtk-4.1 base-devel curl wget file \\
         openssl gtk3 libayatana-appindicator librsvg patchelf"
    )
  fi

  # Docker é o RUNTIME do app (não do build), mas avisar cedo evita a surpresa
  # de instalar o app e ele não subir. Não é bloqueante.
  if ! command -v docker >/dev/null 2>&1; then
    echo "    ⚠️  docker não encontrado no PATH — o app precisa dele em runtime pra subir o FrankMD."
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "" >&2
    echo "❌ pré-requisitos faltando ($_BUILD_OS) — corrija e rode de novo:" >&2
    echo "" >&2
    local m; for m in "${missing[@]}"; do echo "   • $m" >&2; echo "" >&2; done
    exit 1
  fi
}

# ── Versão: ../version.md -> tauri.conf.json + Cargo.toml ────────────────────
# version.md é a fonte da verdade do fork (padrão da casa). Grava a versão nos
# manifests do app pra o instalador e o "Sobre" saírem com o número certo.
# Tolerante: se ../version.md não existir, mantém o que está no tauri.conf.json.
sync_version() {
  if [ ! -f ../version.md ]; then
    echo "    (../version.md ausente — mantendo a versão atual do tauri.conf.json)"
    return 0
  fi
  local ver; ver="$(head -1 ../version.md | tr -d '[:space:]')"
  if [ -z "$ver" ]; then echo "    (../version.md vazio — pulando)"; return 0; fi
  echo "    versão do fork: $ver"
  # awk (POSIX, portável mac/linux) substituindo SÓ a 1ª ocorrência de cada manifesto.
  # tauri.conf.json: a chave "version" de topo.
  awk -v v="$ver" '!d && /"version"[[:space:]]*:/ {sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" v "\""); d=1} {print}' \
    src-tauri/tauri.conf.json > src-tauri/tauri.conf.json.tmp && mv src-tauri/tauri.conf.json.tmp src-tauri/tauri.conf.json
  # Cargo.toml: a 1ª linha 'version = "..."' (a do [package]; deps usam version inline em { }).
  awk -v v="$ver" '!d && /^version = "/ {sub(/"[^"]*"/, "\"" v "\""); d=1} {print}' \
    src-tauri/Cargo.toml > src-tauri/Cargo.toml.tmp && mv src-tauri/Cargo.toml.tmp src-tauri/Cargo.toml
}

# ── macOS: assinatura (Developer ID) + notarização (senha de app) ────────────
NOTARY_SERVICE="frankmd-notarize"
SIGN_ENABLED=0
NOTARIZE_ENABLED=0

setup_macos_signing() {
  [ "$_BUILD_OS" = macOS ] || return 0
  if [ "${NO_SIGN:-0}" -eq 1 ]; then
    echo "    (--no-sign: build de teste, SEM assinar/notarizar)"; return 0
  fi

  if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
    APPLE_SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/{print $2; exit}' || true)"
  fi
  if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
    echo "    ⚠️  sem cert 'Developer ID Application' no keychain — BUILD SAI SEM ASSINAR."
    echo "        (o macOS vai oferecer 'mover p/ lixeira' ao abrir o app baixado)"
    return 0
  fi
  export APPLE_SIGNING_IDENTITY
  SIGN_ENABLED=1
  echo "    ✔ assinatura: $APPLE_SIGNING_IDENTITY"

  if [ -z "${APPLE_TEAM_ID:-}" ]; then
    APPLE_TEAM_ID="$(printf '%s' "$APPLE_SIGNING_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
  fi
  if [ -z "${APPLE_PASSWORD:-}" ]; then
    APPLE_PASSWORD="$(security find-generic-password -s "$NOTARY_SERVICE" -w 2>/dev/null || true)"
  fi
  if [ -z "${APPLE_ID:-}" ]; then
    APPLE_ID="$(security find-generic-password -s "$NOTARY_SERVICE" 2>/dev/null \
      | awk -F'"' '/"acct"/{print $4}' || true)"
  fi

  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    export APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID
    NOTARIZE_ENABLED=1
    echo "    ✔ notarização: $APPLE_ID (team $APPLE_TEAM_ID) — tauri build vai notarizar+staple"
  else
    echo "    ⚠️  vou ASSINAR mas NÃO notarizar (falta credencial). Guarde a senha de app:"
    echo "        security add-generic-password -U -s \"$NOTARY_SERVICE\" -a \"SEU_APPLE_ID\" -w"
  fi
}

verify_macos_signature() {
  [ "$_BUILD_OS" = macOS ] || return 0
  [ "$SIGN_ENABLED" -eq 1 ] || { echo "    (build sem assinatura — nada a verificar)"; return 0; }
  local app dmg
  app="$(find src-tauri/target/release/bundle/macos -maxdepth 1 -name '*.app' 2>/dev/null | head -1 || true)"
  dmg="$(find src-tauri/target/release/bundle/dmg  -maxdepth 1 -name '*.dmg' 2>/dev/null | head -1 || true)"
  if [ -n "$app" ]; then
    echo "  • codesign --verify (deep, strict):"
    if codesign --verify --deep --strict --verbose=2 "$app" >/tmp/_frankmd_cs.txt 2>&1; then
      echo "      ✔ assinatura íntegra"
    else
      echo "      ❌ assinatura inválida:"; sed 's/^/        /' /tmp/_frankmd_cs.txt
    fi
    echo "  • Gatekeeper (spctl assess):"
    spctl -a -t exec -vvv "$app" 2>&1 | sed 's/^/      /' || true
    if xcrun stapler validate "$app" >/dev/null 2>&1; then
      echo "      ✔ .app com staple (abre offline, sem prompt)"
    else
      echo "      ⚠️  .app SEM staple — notarização não rodou/falhou"
    fi
  fi
  if [ -n "$dmg" ] && [ "$NOTARIZE_ENABLED" -eq 1 ] && ! xcrun stapler validate "$dmg" >/dev/null 2>&1; then
    echo "      • notarizando o .dmg (submit + staple)…"
    xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" --wait 2>&1 | sed 's/^/        /' \
      && xcrun stapler staple "$dmg" 2>&1 | sed 's/^/        /' || true
  fi
}

# macOS: destrava imagens .dmg DESTE repo que ficaram montadas de um build anterior.
detach_stale_build_images() {
  [ "$_BUILD_OS" = macOS ] || return 0
  command -v hdiutil >/dev/null 2>&1 || return 0
  local bundle_abs devs d
  bundle_abs="$(pwd)/src-tauri/target/release/bundle"
  devs="$(hdiutil info 2>/dev/null | awk -v b="$bundle_abs" '
    /^image-path/            { p = (index($0, b) > 0) }
    p && /^\/dev\/disk[0-9]/ { print $1; p = 0 }
  ' || true)"
  for d in $devs; do
    echo "    imagem presa de build anterior — ejetando $d"
    hdiutil detach "$d" >/dev/null 2>&1 || hdiutil detach -force "$d" >/dev/null 2>&1 || true
  done
}

SKIP_NPM=0
NO_SIGN=0
SKIP_GIT_PULL=0
BUNDLES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-npm)      SKIP_NPM=1 ;;
    --no-sign)       NO_SIGN=1 ;;
    --skip-git-pull) SKIP_GIT_PULL=1 ;;
    --bundles)       shift; BUNDLES="${1:-}" ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "opção desconhecida: $1 (use --help)" >&2; exit 2 ;;
  esac
  shift
done

echo "==> FrankMD Desktop — build local ($_BUILD_OS)"

step "[git] sincroniza com o remoto (git pull --ff-only)"
git_sync

step "[pré-requisitos] verifica o toolchain (Rust, Node, Xcode/WebKitGTK, Docker)"
preflight

step "[1/4] versão (../version.md -> tauri.conf.json + Cargo.toml)"
sync_version

step "[2/4] tauri CLI (npm install)"
if [ "$SKIP_NPM" -eq 0 ]; then
  npm install --no-audit --no-fund
else
  echo "    (pulado: --skip-npm)"
fi

detach_stale_build_images

# Limpa instaladores de builds anteriores (só o artefato do build ATUAL deve sobrar).
rm -rf src-tauri/target/release/bundle

if [ "$_BUILD_OS" = macOS ]; then
  step "[macOS] assinatura + notarização (Developer ID + notarytool)"
  setup_macos_signing
fi

# AppImage (Linux): destrava o linuxdeploy em VM/sem-GPU e evita o dpkg-query lento.
if [ "$_BUILD_OS" = Linux ]; then
  ARCH="$(uname -m)"; export ARCH
  export DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1
  export APPIMAGE_EXTRACT_AND_RUN=1
  export NO_STRIP=1
fi

step "[3/4] Tauri build"
if [ -n "$BUNDLES" ]; then
  npx tauri build --bundles "$BUNDLES"
else
  npx tauri build
fi

step "[4/4] artefatos"
echo "[OK] Instaladores em desktop/src-tauri/target/release/bundle/:"
find src-tauri/target/release/bundle -maxdepth 2 -type f \
  \( -name '*.deb' -o -name '*.AppImage' -o -name '*.rpm' -o -name '*.dmg' \) \
  -exec ls -lh {} \; 2>/dev/null || true

if [ "$_BUILD_OS" = macOS ]; then
  step "[macOS] verificação (codesign / spctl / stapler)"
  verify_macos_signature
fi
_summary
