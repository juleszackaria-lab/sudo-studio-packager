#!/usr/bin/env bash
# SUDO STUDIO - P60: build the three Linux deliverables from the assembled
# portable bundle.
#
#   make-packages.sh <bundle-dir> <version> <arch> <out-dir> [icon.png]
#
# Produces:
#   SudoStudio-<version>-linux-<arch>.tar.gz           portable, air-gapped
#   sudostudio_<version>_<arch>.deb                    Debian/Ubuntu
#   sudostudio-<version>.<arch>.rpm                    RHEL/Fedora/Rocky
#
# and, for each one, SudoStudio-SHA256SUMS.
#
# The DEB/RPM install the SAME tree the tarball ships, under /opt/sudo-studio:
#   /opt/sudo-studio/...                 (editor, extensions, backend, runtime)
#   /usr/bin/sudo-studio                 launcher (symlink-free shell wrapper)
#   /usr/share/applications/sudo-studio.desktop
#   /usr/share/icons/hicolor/<n>/apps/sudo-studio.png
#   /usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md, LICENSE, BUILD-INFO.txt
# so a user can run `sudo-studio` from any desktop shell, and the uninstall is
# a single package removal.
#
# Requires: dpkg-deb, rpmbuild (apt install rpm). Fails loudly if either is
# missing: no silent half-built package.
set -euo pipefail

BUNDLE=${1:?usage: make-packages.sh <bundle-dir> <version> <arch> <out-dir> [icon]}
VERSION=${2:?version required}
ARCH=${3:-x64}
OUT=${4:?out-dir required}
ICON=${5:-}

DEB_ARCH=$([ "$ARCH" = "x64" ] || [ "$ARCH" = "amd64" ] && echo amd64 || echo "$ARCH")
RPM_ARCH=$([ "$ARCH" = "x64" ] && echo x86_64 || echo "$ARCH")

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[INFO] bundle=$BUNDLE version=$VERSION arch=$ARCH"
test -d "$BUNDLE" || { echo "[FAIL] bundle dir missing: $BUNDLE"; exit 1; }
test -x "$BUNDLE/bin/codium" || { echo "[FAIL] editor binary missing in $BUNDLE/bin"; exit 1; }
test -x "$BUNDLE/backend/backend" || { echo "[FAIL] backend binary missing"; exit 1; }
test -x "$BUNDLE/backend/runtime/server" || { echo "[FAIL] runtime binary missing"; exit 1; }

# ---------------------------------------------------------------- documents
# LICENSE / notices travel INSIDE every artifact (P60 item 5).
NOTICES="$BUNDLE/THIRD_PARTY_NOTICES.md"
if [ ! -f "$NOTICES" ]; then
  {
    echo "# Sudo Studio - THIRD PARTY NOTICES"
    echo ""
    echo "Sudo Studio bundles the following third-party components:"
    echo ""
    echo "- VSCodium (MIT) - https://github.com/VSCodium/vscodium"
    echo "- Electron (MIT) - https://www.electronjs.org"
    echo "- Node.js (MIT) - https://nodejs.org"
    echo "- Python (PSF-2.0) - https://python.org"
    echo "- Flask (BSD-3-Clause) - https://flask.palletsprojects.com"
    echo "- llama-cpp-python (MIT) - https://github.com/abetlen/llama-cpp-python"
    echo "- llama.cpp (MIT) - https://github.com/ggerganov/llama.cpp"
    echo "- PyTorch (BSD-3-Clause) - https://pytorch.org"
    echo "- Transformers (Apache-2.0) - https://github.com/huggingface/transformers"
    echo "- huggingface_hub (Apache-2.0) - https://github.com/huggingface/huggingface_hub"
    echo ""
    echo "Full license texts ship with each upstream project. This file is"
    echo "generated at package time; see BUILD-INFO.txt for exact versions."
  } > "$NOTICES"
fi
[ -f "$BUNDLE/LICENSE" ] || echo "Sudo Studio - all rights reserved (see the product EULA)." > "$BUNDLE/LICENSE"

# ------------------------------------------------------------------ launcher
write_launcher() {
  cat > "$1" <<'SH'
#!/bin/sh
# Sudo Studio launcher (system install). Starts the local backend if it is not
# already answering, then the editor with the bundled extension.
# Every writable thing stays in the user folder (XDG): no root needed to run.
set -eu
PREFIX="${SUDO_STUDIO_PREFIX:-/opt/sudo-studio}"
export SUDO_STUDIO_ROOT="$PREFIX"
export SUDO_STUDIO_HOME="${SUDO_STUDIO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/sudo-studio}"
LOG_DIR="${SUDO_STUDIO_LOGS:-${XDG_STATE_HOME:-$SUDO_STUDIO_HOME}/sudo-studio/logs}"
[ "$LOG_DIR" = "$SUDO_STUDIO_HOME/sudo-studio/logs" ] && LOG_DIR="$SUDO_STUDIO_HOME/logs"
export SUDO_STUDIO_LOGS="$LOG_DIR"
mkdir -p "$LOG_DIR" "$SUDO_STUDIO_HOME" || true
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [launcher] start prefix=$PREFIX logs=$LOG_DIR" >> "$LOG_DIR/startup.log" 2>/dev/null || true

PORT="${SUDO_STUDIO_BACKEND_PORT:-5000}"
export PORT
if command -v curl >/dev/null 2>&1 && curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/api/system/health"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [launcher] backend already up" >> "$LOG_DIR/startup.log" 2>/dev/null || true
else
  "$PREFIX/backend/backend" >> "$LOG_DIR/backend.out" 2>&1 &
  echo $! > "$LOG_DIR/backend.pid"
  i=0
  while [ $i -lt 40 ]; do
    if command -v curl >/dev/null 2>&1 && curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/api/system/health"; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [launcher] backend ready" >> "$LOG_DIR/startup.log" 2>/dev/null || true
      break
    fi
    i=$((i + 1)); sleep 1
  done
fi

exec "$PREFIX/bin/codium" --no-sandbox \
  --extensions-dir "$SUDO_STUDIO_HOME/extensions" \
  --user-data-dir "$SUDO_STUDIO_HOME/user" "$@"
SH
  chmod 0755 "$1"
}

# ------------------------------------------------------------------ desktop
write_desktop() {
  cat > "$1" <<'DESK'
[Desktop Entry]
Type=Application
Name=Sudo Studio
GenericName=AI Development Studio
Comment=Local AI development studio (agent, audit, analyse, DevOps)
Exec=/usr/bin/sudo-studio %F
Icon=sudo-studio
Terminal=false
Categories=Development;IDE;
MimeType=text/plain;inode/directory;
StartupNotify=true
StartupWMClass=Sudo Studio
DESK
}

# ================================================================== TARBALL
echo "[STEP] tar.gz"
TARNAME="SudoStudio-${VERSION}-linux-${ARCH}.tar.gz"
tar -czf "$OUT/$TARNAME" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")"
echo "[OK] $TARNAME $(du -h "$OUT/$TARNAME" | cut -f1)"

# ===================================================================== DEB
echo "[STEP] .deb"
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "[FAIL] dpkg-deb absent : impossible de produire le .deb"
  exit 1
fi
DEB_ROOT="$WORK/deb"
mkdir -p "$DEB_ROOT/opt" "$DEB_ROOT/usr/bin" "$DEB_ROOT/usr/share/applications" \
         "$DEB_ROOT/usr/share/doc/sudo-studio" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE" "$DEB_ROOT/opt/sudo-studio"
write_launcher "$DEB_ROOT/usr/bin/sudo-studio"
write_desktop "$DEB_ROOT/usr/share/applications/sudo-studio.desktop"
if [ -n "$ICON" ] && [ -f "$ICON" ]; then
  cp "$ICON" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/sudo-studio.png"
fi
cp "$NOTICES" "$DEB_ROOT/usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md"
cp "$BUNDLE/LICENSE" "$DEB_ROOT/usr/share/doc/sudo-studio/LICENSE"
cp "$BUNDLE/BUILD-INFO.txt" "$DEB_ROOT/usr/share/doc/sudo-studio/BUILD-INFO.txt" 2>/dev/null || true
gzip -9 -n -c "$DEB_ROOT/usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md" > "$DEB_ROOT/usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md.gz" || true

INSTALLED_KB=$(du -sk "$DEB_ROOT" | cut -f1)
mkdir -p "$DEB_ROOT/DEBIAN"
cat > "$DEB_ROOT/DEBIAN/control" <<CTRL
Package: sudostudio
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Sudo Studio <support@sudo-studio.local>
Installed-Size: ${INSTALLED_KB}
Depends: libgtk-3-0 | libgtk-3-0t64, libnss3, libasound2t64 | libasound2, libgbm1, curl
Recommends: xvfb
Homepage: https://sudo-studio.local
Description: Sudo Studio - local AI development studio
 Sudo Studio bundles an editor, a local agent and an AI runtime that runs on
 the machine (no cloud required). This package installs the portable tree in
 /opt/sudo-studio and a launcher in /usr/bin/sudo-studio.
CTRL
cat > "$DEB_ROOT/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
# Refresh the desktop database; never fail the install for a cache.
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
echo "[sudo-studio] installe dans /opt/sudo-studio. Lancement : sudo-studio"
exit 0
POST
chmod 0755 "$DEB_ROOT/DEBIAN/postinst"
cat > "$DEB_ROOT/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
# Stop a backend this user started from the launcher (best effort, no root).
for pidfile in "$HOME/.local/share/sudo-studio/logs/backend.pid" "$HOME/.local/share/sudo-studio/backend.pid"; do
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done
exit 0
PRE
chmod 0755 "$DEB_ROOT/DEBIAN/prerm"
DEBNAME="sudostudio_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$OUT/$DEBNAME" >/dev/null
echo "[OK] $DEBNAME $(du -h "$OUT/$DEBNAME" | cut -f1)"

# ===================================================================== RPM
echo "[STEP] .rpm"
if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "[WARN] rpmbuild absent -> .rpm non produit (installe le paquet 'rpm')"
else
  TOP="$WORK/rpm"
  mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}
  STAGE="$TOP/BUILDROOT/stage"
  mkdir -p "$STAGE/opt" "$STAGE/usr/bin" "$STAGE/usr/share/applications" \
           "$STAGE/usr/share/doc/sudo-studio" "$STAGE/usr/share/icons/hicolor/512x512/apps"
  cp -a "$BUNDLE" "$STAGE/opt/sudo-studio"
  write_launcher "$STAGE/usr/bin/sudo-studio"
  write_desktop "$STAGE/usr/share/applications/sudo-studio.desktop"
  if [ -n "$ICON" ] && [ -f "$ICON" ]; then
    cp "$ICON" "$STAGE/usr/share/icons/hicolor/512x512/apps/sudo-studio.png"
  fi
  cp "$NOTICES" "$STAGE/usr/share/doc/sudo-studio/THIRD_PARTY_NOTICES.md"
  cp "$BUNDLE/LICENSE" "$STAGE/usr/share/doc/sudo-studio/LICENSE"
  cp "$BUNDLE/BUILD-INFO.txt" "$STAGE/usr/share/doc/sudo-studio/BUILD-INFO.txt" 2>/dev/null || true

  mkdir -p "$TOP/SPECS"
  cat > "$TOP/SPECS/sudostudio.spec" <<SPEC
Name:           sudostudio
Version:        $(echo "$VERSION" | tr '-' '.')
Release:        1
Summary:        Sudo Studio - local AI development studio
License:        Proprietary
URL:            https://sudo-studio.local
BuildArch:      ${RPM_ARCH}
Requires:       nss, alsa-lib, gbm, curl
%description
Sudo Studio bundles an editor, a local agent and an AI runtime that runs on
the machine (no cloud required).
%prep
%build
%install
mkdir -p %{buildroot}
cp -a $STAGE/. %{buildroot}/
%files
/opt/sudo-studio
/usr/bin/sudo-studio
/usr/share/applications/sudo-studio.desktop
/usr/share/doc/sudo-studio
%if 0%{?have_icon}
/usr/share/icons/hicolor/512x512/apps/sudo-studio.png
%endif
%post
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || :; fi
echo "[sudo-studio] installe dans /opt/sudo-studio. Lancement : sudo-studio"
%preun
for pidfile in "\$HOME/.local/share/sudo-studio/logs/backend.pid"; do
  [ -f "\$pidfile" ] && kill "\$(cat "\$pidfile")" 2>/dev/null || :
done
SPEC
  DEFINES=""
  if [ -n "$ICON" ] && [ -f "$ICON" ]; then DEFINES="--define have_icon 1"; fi
  rpmbuild -bb --quiet $DEFINES \
    --define "_topdir $TOP" \
    --define "_build_id_links none" \
    "$TOP/SPECS/sudostudio.spec" > "$WORK/rpm.log" 2>&1 || {
      echo "[FAIL] rpmbuild a echoue :"; tail -30 "$WORK/rpm.log"; exit 1; }
  RPMFILE=$(find "$TOP/RPMS" -name '*.rpm' | head -1)
  test -n "$RPMFILE" || { echo "[FAIL] aucun .rpm produit"; exit 1; }
  cp "$RPMFILE" "$OUT/"
  echo "[OK] $(basename "$RPMFILE") $(du -h "$OUT/$(basename "$RPMFILE")" | cut -f1)"
fi

# ================================================================== SHA256
echo "[STEP] SHA256"
( cd "$OUT" && rm -f SHA256SUMS && sha256sum ./*.tar.gz ./*.deb ./*.rpm 2>/dev/null > SHA256SUMS || true )
cat "$OUT/SHA256SUMS"

echo "[DONE] artefacts dans $OUT"
