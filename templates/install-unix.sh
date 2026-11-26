#!/usr/bin/env bash
# install-unix.sh
# ---------------------------------------------------------------------------------------------
# Instalador para Linux y macOS generado por py-installer (el mismo archivo sirve para los dos).
# Todo va a carpetas de tu usuario (sin sudo): consigue un Python propio con "uv", prepara el
# programa y deja un acceso en el menu de aplicaciones. Volver a ejecutarlo actualiza.
# Para desinstalar:  bash "<carpeta de datos>/uninstall.sh"  (la ruta se muestra al terminar)
#
# Variables opcionales (<PREFIJO> es el del programa, se muestra mas abajo en ENV_PREFIX):
#   <PREFIJO>_NO_LAUNCH=1   no abrir al terminar          <PREFIJO>_BASE_URL=...   descargar de otra direccion
#   <PREFIJO>_UV=/ruta/uv   usar ese uv                   <PREFIJO>_PYTHON=/ruta   usar ese Python
# ---------------------------------------------------------------------------------------------
set -euo pipefail

# @@PYI_CONFIG@@

# textos en el idioma de este instalador (LANG_CODE y _tx: los pone py-installer desde lang/pyi.<idioma>.json)
# T clave [nombre=valor ...]: el texto con sus {variables} sustituidas (vale para el bash 3.2 de macOS)
T() {
  local k="$1" s kv p v out; shift
  s="$(_tx "$k")"; [ -n "$s" ] || s="$k"
  for kv in "$@"; do
    p="{${kv%%=*}}"; v="${kv#*=}"; out=""
    while [[ "$s" == *"$p"* ]]; do out="$out${s%%"$p"*}$v"; s="${s#*"$p"}"; done
    s="$out$s"
  done
  printf '%s' "$s"
}

opt() { local v="${ENV_PREFIX}_$1"; printf '%s' "${!v:-}"; }
[ -n "$(opt BASE_URL)" ] && BASE="$(opt BASE_URL)"
BASE="${BASE%/}"; DL="$BASE/dl"

say()  { printf '      %s\n' "$*"; }
step() { printf '\n\033[36m[%s/5] %s\033[0m\n' "$1" "$2"; }
die()  { printf '\n\033[31m  %s\033[0m\n' "$(T inst.error msg="$*")" >&2; [ -n "${LOG:-}" ] && printf '  %s\n' "$(T inst.log_at path="$LOG")" >&2; exit 1; }
trap 'die "$(T inst.stopped line=$LINENO)"' ERR

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  UVARCH=x86_64 ;;
  aarch64|arm64) UVARCH=aarch64 ;;
  *) die "$(T inst.arch_unsupported arch="$ARCH")" ;;
esac
case "$OS" in
  Linux)  KIND=linux; TRIPLE="$UVARCH-unknown-linux-gnu"
          [ "$SUPPORTS_LINUX" = 1 ] || die "$(T inst.not_for_os app="$APP_NAME" os=Linux)"
          ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/$FOLDER"; PROG="$ROOT/app" ;;
  Darwin) KIND=mac;   TRIPLE="$UVARCH-apple-darwin"
          [ "$SUPPORTS_MACOS" = 1 ] || die "$(T inst.not_for_os app="$APP_NAME" os=macOS)"
          ROOT="$HOME/Library/Application Support/$FOLDER"; PROG="$ROOT/app" ;;
  *) die "$(T inst.os_unsupported os="$OS")" ;;
esac
if [ "$KIND" = linux ] && { ldd --version 2>&1 | grep -qi musl; }; then
  TRIPLE="$UVARCH-unknown-linux-musl"
fi
BIN="$ROOT/bin"; RT="$ROOT/runtime"; STAGE="$ROOT/stage"

fetch() {   # fetch URL DESTINO (con reintentos)
  local url="$1" dest="$2" n
  mkdir -p "$(dirname "$dest")"
  for n in 1 2 3; do
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 --connect-timeout 20 -o "$dest" "$url" && [ -s "$dest" ] && return 0
    elif command -v wget >/dev/null 2>&1; then wget -q -T 20 -O "$dest" "$url" && [ -s "$dest" ] && return 0
    else die "$(T inst.need_curl)"; fi
    sleep $((2 * n))
  done
  return 1
}
need() { fetch "$1" "$2" || die "$(T inst.dl_failed_sh url="$1")"; }

printf '\n\033[33m  ==============================\n        %s\n  ==============================\033[0m\n' "$APP_NAME"
echo "  $(T inst.intro1_unix)"
echo "  $(T inst.intro2)"

mkdir -p "$ROOT" "$BIN" "$RT" "$STAGE" "$PROG" "$ROOT/logs"
LOG="$ROOT/logs/instalacion.log"
exec > >(tee -a "$LOG") 2>&1            # todo lo que sale por pantalla queda tambien en el registro
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="; echo "$(T inst.sysinfo_unix os="$(uname -srm)" bash="$BASH_VERSION" user="$(id -un)")"
say "$(T inst.log path="$LOG")"
say "$(T inst.prog_at path="$PROG")"
say "$(T inst.lang lang="$LANG_CODE")"
pkill -f "$PROG/$ENTRY" 2>/dev/null || true

# --- 1) uv ---------------------------------------------------------------------------------------------------------
step 1 "$(T inst.step.uv)"
if [ -n "$(opt UV)" ] && [ -x "$(opt UV)" ]; then
  UV="$(opt UV)"; say "$(T inst.using path="$UV")"
else
  UV="$BIN/uv"
  if [ -x "$UV" ] && "$UV" --version >/dev/null 2>&1; then
    say "$(T inst.already)"
  else
    TMPD="$(mktemp -d)"
    need "https://github.com/astral-sh/uv/releases/latest/download/uv-$TRIPLE.tar.gz" "$TMPD/uv.tgz"
    tar -xzf "$TMPD/uv.tgz" -C "$TMPD"
    F="$(find "$TMPD" -type f -name uv | head -n 1)"
    [ -n "$F" ] || die "$(T inst.no_uv_bin)"
    cp "$F" "$UV"; chmod +x "$UV"; rm -rf "$TMPD"
    say "$(T inst.done)"
  fi
fi

# --- 2) Python propio ----------------------------------------------------------------------------------------------
step 2 "$(T inst.step.python ver="$PY_VER")"
export UV_CACHE_DIR="$ROOT/cache" UV_PYTHON_BIN_DIR="$BIN/python" UV_PYTHON_PREFERENCE=only-managed UV_PYTHON_DOWNLOADS=automatic UV_NO_PROGRESS=1
if [ -n "$(opt PYTHON)" ] && [ -x "$(opt PYTHON)" ]; then
  PY="$(opt PYTHON)"; say "$(T inst.using path="$PY")"
else
  export UV_PYTHON_INSTALL_DIR="$RT"
  # una carpeta a medias de un intento anterior hace fallar a uv: se borra
  for d in "$RT"/cpython-"$PY_VER"*; do if [ -d "$d" ] && [ ! -e "$d/lib" ]; then rm -rf "$d"; fi; done
  if ! "$UV" python install "$PY_VER"; then
    say "$(T inst.retry_slow)"
    UV_HTTP_TIMEOUT=300 UV_CONCURRENT_DOWNLOADS=1 "$UV" python install "$PY_VER" || die "$(T inst.no_python_unix ver="$PY_VER")"
  fi
  PY="$("$UV" python find "$PY_VER" | head -n 1)"
  [ -x "$PY" ] || die "$(T inst.py_not_found ver="$PY_VER")"
  say "$PY"
fi
case "$CHECK_CODE" in *tkinter*)
  "$PY" -c "import tkinter; tkinter.Tcl()" >/dev/null 2>&1 || die "$(T inst.no_tk url="$ISSUES_URL")" ;;
esac

# --- 3) el programa ------------------------------------------------------------------------------------------------
step 3 "$(T inst.step.download app="$APP_NAME")"
for f in "${FILES[@]}" VERSION; do need "$DL/$f" "$STAGE/$f"; done
if [ "$HAS_PNG" = 1 ]; then fetch "$DL/icon.png" "$STAGE/icon.png" || say "$(T inst.no_icon)"; fi
if [ "$KIND" = mac ] && [ "$HAS_ICNS" = 1 ]; then fetch "$DL/icon.icns" "$STAGE/icon.icns" || true; fi
if [ -n "$DATA_ZIP" ]; then
  if fetch "$DL/$DATA_ZIP" "$STAGE/$DATA_ZIP"; then
    "$PY" -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$STAGE/$DATA_ZIP" "$STAGE/data" || rm -rf "$STAGE/data"
  else
    say "$(T inst.no_data_unix)"
  fi
fi
VERSION="$(tr -d '[:space:]' < "$STAGE/VERSION")"
say "$(T inst.version v="$VERSION")"

# --- 4) entorno con sus librerias (la parte lenta) -----------------------------------------------------------------
step 4 "$(T inst.step.install)"
for f in "${FILES[@]}" VERSION; do mkdir -p "$(dirname "$PROG/$f")"; cp "$STAGE/$f" "$PROG/$f"; done
if [ -f "$STAGE/icon.png" ]; then cp "$STAGE/icon.png" "$PROG/icon.png"; fi
if [ -d "$STAGE/data" ]; then   # los datos iniciales no pisan lo que ya tengas
  (cd "$STAGE/data" && find . -type f) | while IFS= read -r f; do
    [ -e "$PROG/$f" ] || { mkdir -p "$(dirname "$PROG/$f")"; cp "$STAGE/data/$f" "$PROG/$f"; }
  done
fi
VENV="$PROG/$VENV_DIR"; VPY="$VENV/bin/python"
if [ -x "$VPY" ] && "$VPY" -c "import pip, sys; assert '%d.%d' % sys.version_info[:2] == '$PY_VER'" >/dev/null 2>&1; then
  say "$(T inst.venv_ok)"
else
  rm -rf "$VENV"
  "$UV" venv --seed --python "$PY" "$VENV" || die "$(T inst.venv_fail_unix)"
fi
install_pkgs() { "$UV" pip install --python "$VPY" --upgrade -q "$@" || "$VPY" -m pip install --disable-pip-version-check --no-cache-dir -q --upgrade "$@"; }
if [ "${#REQUIRED[@]}" -gt 0 ]; then
  say "$(T inst.libs list="${REQUIRED[*]}")"
  install_pkgs "${REQUIRED[@]}" || die "$(T inst.libs_fail_unix list="${REQUIRED[*]}")"
fi
for ((i = 0; i < ${#OPTIONAL_PKG[@]}; i++)); do
  install_pkgs "${OPTIONAL_PKG[$i]}" || say "$(T inst.opt_fail_unix pkg="${OPTIONAL_PKG[$i]}" why="${OPTIONAL_WHY[$i]}")"
done
for ((i = 0; i < ${#EX_URL[@]}; i++)); do
  case " ${EX_OS[$i]} " in *" $KIND "*|*" any "*) ;; *) continue ;; esac
  DST="$PROG/${EX_TO[$i]}"; MISSING=0
  for n in ${EX_EXTRACT[$i]}; do if [ ! -e "$DST/$n" ]; then MISSING=1; fi; done
  if [ "$MISSING" = 0 ]; then say "$(T inst.extra_ok label="${EX_LABEL[$i]}")"; continue; fi
  say "$(T inst.extra_dl label="${EX_LABEL[$i]}")"
  ARC="$ROOT/extra.bin"
  if fetch "${EX_URL[$i]}" "$ARC" && "$PY" - "$ARC" "$DST" "$(T inst.extra_missing list=)" ${EX_EXTRACT[$i]} <<'PYEOF'
import os, stat, sys, tarfile, zipfile
arc, dst, msg, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
os.makedirs(dst, exist_ok=True)
got = set()
if zipfile.is_zipfile(arc):
    with zipfile.ZipFile(arc) as z:
        for i in z.infolist():
            b = os.path.basename(i.filename)
            if b in names and b not in got:
                open(os.path.join(dst, b), 'wb').write(z.read(i)); got.add(b)
else:
    with tarfile.open(arc) as t:
        for m in t.getmembers():
            b = os.path.basename(m.name)
            if m.isfile() and b in names and b not in got:
                open(os.path.join(dst, b), 'wb').write(t.extractfile(m).read()); got.add(b)
for b in got:
    p = os.path.join(dst, b); os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
missing = [n for n in names if n not in got]
if missing:
    sys.exit(msg + ', '.join(missing))
PYEOF
  then rm -f "$ARC"
  else
    rm -f "$ARC"
    MSG="$(T inst.extra_fail_unix label="${EX_LABEL[$i]}" url="${EX_URL[$i]}" files="${EX_EXTRACT[$i]}" dir="$DST")"
    if [ "${EX_REQ[$i]}" = 1 ]; then die "$MSG"; else say "$(T inst.warn msg="$MSG")"; fi
  fi
done
if [ -n "$POST_INSTALL" ]; then
  say "$(T inst.post)"
  if { : < /dev/tty; } 2>/dev/null; then   # con "curl ... | bash" la entrada no es la terminal: se le devuelve para que pueda preguntar
    "$VPY" -u "$PROG/$POST_INSTALL" "$PROG" < /dev/tty || die "$(T inst.post_fail file="$POST_INSTALL")"
  else
    "$VPY" -u "$PROG/$POST_INSTALL" "$PROG" || die "$(T inst.post_fail file="$POST_INSTALL")"
  fi
fi

# --- 5) accesos, desinstalador y comprobacion ----------------------------------------------------------------------
step 5 "$(T inst.step.finish_unix)"
SHORTCUTS=()
if [ "$KIND" = linux ]; then
  APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"; mkdir -p "$APPS"
  ICON="$APP_ID"
  if [ -f "$PROG/icon.png" ]; then
    ICONDIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
    mkdir -p "$ICONDIR"; cp "$PROG/icon.png" "$ICONDIR/$APP_ID.png"; SHORTCUTS+=("$ICONDIR/$APP_ID.png")
    ICON="$PROG/icon.png"
  fi
  TERM_FLAG=false; [ "$GUI" = 1 ] || TERM_FLAG=true
  ASSOC_ARG=""; ASSOC_MIMELINE=""
  if [ -n "$ASSOC_MIMES" ]; then
    ASSOC_ARG=" %f"
    ASSOC_MIMELINE="MimeType=$(printf '%s;' $ASSOC_MIMES)"
    MIMEDIR="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
    if [ -n "$ASSOC_MIME_XML" ]; then             # tipos propios del programa (los que no tienen uno conocido)
      mkdir -p "$MIMEDIR/packages"
      printf '%s' "$ASSOC_MIME_XML" > "$MIMEDIR/packages/$APP_ID.xml"
      SHORTCUTS+=("$MIMEDIR/packages/$APP_ID.xml")
      command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$MIMEDIR" >/dev/null 2>&1 || true
    fi
  fi
  DESK="$APPS/$APP_ID.desktop"
  cat > "$DESK" <<DEOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$DESCRIPTION
Exec="$VPY" "$PROG/$ENTRY"$ASSOC_ARG
Path=$PROG
Icon=$ICON
Terminal=$TERM_FLAG
Categories=Utility;
StartupWMClass=$APP_ID
$ASSOC_MIMELINE
DEOF
  chmod +x "$DESK"; SHORTCUTS+=("$DESK")
  if [ "$DESKTOP" = 1 ]; then
    DD="$(xdg-user-dir DESKTOP 2>/dev/null || true)"; [ -n "$DD" ] || DD="$HOME/Desktop"
    if [ -d "$DD" ] && [ "$DD" != "$HOME" ]; then
      cp "$DESK" "$DD/$APP_ID.desktop"; chmod +x "$DD/$APP_ID.desktop"; SHORTCUTS+=("$DD/$APP_ID.desktop")
      command -v gio >/dev/null 2>&1 && gio set "$DD/$APP_ID.desktop" metadata::trusted true 2>/dev/null || true
    fi
  fi
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" >/dev/null 2>&1 || true
  # los tipos propios se abren con el programa con doble clic; los conocidos (.md...) solo se anaden a "Abrir con"
  if [ -n "$ASSOC_OWN_MIMES" ] && command -v xdg-mime >/dev/null 2>&1; then
    for mm in $ASSOC_OWN_MIMES; do xdg-mime default "$APP_ID.desktop" "$mm" 2>/dev/null || true; done
  fi
  [ -n "$ASSOC_EXTS" ] && say "$(T inst.assoc_openwith exts="$ASSOC_EXTS")"
  LAUNCH=(nohup setsid "$VPY" "$PROG/$ENTRY")
else
  mkdir -p "$HOME/Applications"
  if [ "$GUI" = 1 ]; then
    APP="$HOME/Applications/$LINK_NAME.app"
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    ICONKEY=""
    if [ -f "$STAGE/icon.icns" ]; then cp "$STAGE/icon.icns" "$APP/Contents/Resources/icon.icns"; ICONKEY="<key>CFBundleIconFile</key><string>icon</string>"; fi
    cat > "$APP/Contents/Info.plist" <<PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>io.github.$BUNDLE_OWNER.$APP_ID</string>
<key>CFBundleExecutable</key><string>launcher</string>
$ICONKEY
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>NSHighResolutionCapable</key><true/>
$MAC_DOC_TYPES
</dict></plist>
PLEOF
    cat > "$APP/Contents/MacOS/launcher" <<LAEOF
#!/bin/bash
cd "$PROG"
echo "[\$(date '+%F %T')] arranque" >> "$PROG/arranque.log"
exec "$VPY" -u "$PROG/$ENTRY" >> "$PROG/arranque.log" 2>&1
LAEOF
    chmod +x "$APP/Contents/MacOS/launcher"
    SHORTCUTS+=("$APP")
    if [ -n "$MAC_DOC_TYPES" ]; then              # que macOS sepa ya que tipos abre (para "Abrir con")
      LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      [ -x "$LSR" ] && "$LSR" -f "$APP" >/dev/null 2>&1 || true
      say "$(T inst.assoc_openwith exts="$ASSOC_EXTS")"
    fi
    LAUNCH=(open "$APP")
  else
    CMDF="$HOME/Applications/$LINK_NAME.command"
    printf '#!/bin/bash\ncd "%s"\nexec "%s" "%s" "$@"\n' "$PROG" "$VPY" "$PROG/$ENTRY" > "$CMDF"; chmod +x "$CMDF"
    SHORTCUTS+=("$CMDF")
    LAUNCH=(open "$CMDF")
  fi
fi

# datos de la instalacion, por si el programa los necesita
"$PY" - "$PROG/install_info.json" "$APP_ID" "$APP_NAME" "$VERSION" "$BASE" "$PY" "$VENV" "$PROG" "$ROOT" "py-installer $PYI_VERSION" "$LANG_CODE" <<'PYEOF'
import json, sys, datetime
keys = ['id', 'name', 'version', 'base_url', 'python', 'venv', 'program_dir', 'data_dir', 'installer', 'lang']
info = dict(zip(keys, sys.argv[2:]))
info['installed_at'] = datetime.datetime.now().isoformat(timespec='seconds')
json.dump(info, open(sys.argv[1], 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PYEOF
# idioma del programa (lang-kit): el de este instalador, salvo que ya hubiera uno elegido (reinstalar no lo cambia)
[ -e "$PROG/lang.json" ] || printf '{"lang": "%s"}' "$LANG_CODE" > "$PROG/lang.json"

# desinstalador
{
  echo '#!/usr/bin/env bash'
  echo "# Desinstala $APP_NAME (accesos, programa y Python propio)."
  printf 'PROG=%q; ROOT=%q; ENTRY=%q\n' "$PROG" "$ROOT" "$ENTRY"
  printf 'SHORTCUTS=('; printf '%q ' "${SHORTCUTS[@]}"; printf ')\n'
  printf 'KEEP=('; if [ "${#KEEP[@]}" -gt 0 ]; then printf '%q ' "${KEEP[@]}"; fi; printf ')\n'
  printf 'TX_ASK=%q; TX_ASK_DATA=%q; TX_CANCELLED=%q; TX_DONE=%q\n' "$(T uninst.ask_sh) " "$(T uninst.ask_data_sh) " "$(T uninst.cancelled)" "$(T uninst.done_sh)"
  cat <<'UNEOF'
# uso:  uninstall.sh [--si] [--borrar-datos]   (--si: sin preguntar; sin --borrar-datos se conservan tus datos)
SI=0; DEL=0; for a in "$@"; do case "$a" in --si) SI=1 ;; --borrar-datos) DEL=1 ;; esac; done
if [ "$SI" = 0 ]; then
  if { : < /dev/tty; } 2>/dev/null; then exec 3< /dev/tty; else exec 3<&0; fi
  read -r -p "$TX_ASK" r <&3 || r=n
  case "$r" in s|S|y|Y) ;; *) echo "$TX_CANCELLED"; exit 0 ;; esac
  if [ "${#KEEP[@]}" -gt 0 ] && [ "$DEL" = 0 ]; then
    read -r -p "$TX_ASK_DATA" r <&3 || r=n
    case "$r" in s|S|y|Y) DEL=1 ;; esac
  fi
fi
[ "${#KEEP[@]}" -gt 0 ] || DEL=1
pkill -f "$PROG/$ENTRY" 2>/dev/null || true
rm -rf "${SHORTCUTS[@]}"
if [ "$DEL" = 1 ]; then
  rm -rf "$PROG"
else
  for f in "$PROG"/* "$PROG"/.[!.]*; do
    [ -e "$f" ] || continue
    k=0; for n in "${KEEP[@]}"; do [ "$(basename "$f")" = "$n" ] && k=1; done
    [ "$k" = 1 ] || rm -rf "$f"
  done
fi
rm -rf "$ROOT/runtime" "$ROOT/bin" "$ROOT/cache" "$ROOT/stage" "$ROOT/logs"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "${XDG_DATA_HOME:-$HOME/.local/share}/mime" >/dev/null 2>&1 || true
rm -f "$0"
rmdir "$ROOT" 2>/dev/null || true
echo "$TX_DONE"
UNEOF
} > "$ROOT/uninstall.sh"
chmod +x "$ROOT/uninstall.sh"

rm -rf "$STAGE"

# comprobacion: ¿cargan de verdad las librerias?
SMOKE_OK=1
if [ -n "$CHECK_CODE" ]; then
  say "$(T inst.checking)"
  if SM="$(env ${CHECK_ENV[@]+"${CHECK_ENV[@]}"} "$VPY" -c "$CHECK_CODE
print('PYI_OK')" 2>&1)" && [ "${SM##*$'\n'}" = "PYI_OK" ]; then
    say "$(T inst.libs_ok)"
  else
    SMOKE_OK=0
    printf '\n\033[33m  %s\033[0m\n%s\n' "$(T inst.libs_broken_unix)" "$(printf '%s\n' "$SM" | tail -n 8)"
    echo "  $(T inst.log_at path="$LOG")"
  fi
fi

printf '\n\033[32m  %s\033[0m\n' "$(T inst.ready app="$APP_NAME")"
if [ "$KIND" = mac ]; then
  echo "  $(T inst.find_mac name="$LINK_NAME")"
else
  echo "  $(T inst.find_linux name="$APP_NAME")"
fi
echo "  $(T inst.uninstall_how cmd="bash \"$ROOT/uninstall.sh\"")"
if [ -z "$(opt NO_LAUNCH)" ] && [ "$SMOKE_OK" = 1 ]; then
  (cd "$PROG" && "${LAUNCH[@]}" >/dev/null 2>&1 &) || true
fi
[ "$SMOKE_OK" = 1 ] || exit 2
exit 0
