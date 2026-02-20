#!/usr/bin/env bash
set -euo pipefail

RST='\033[0m'
BLD='\033[1m'
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[1;36m'
WHT='\033[1;37m'
DIM='\033[2m'

INSTALL_DIR="${1:-$HOME/qemu-local}"
DEB_DIR="$INSTALL_DIR/debs"
EXTRACT_DIR="$INSTALL_DIR/extracted"
BIN_DIR="$INSTALL_DIR/bin"
START_TIME=$(date +%s)

PACKAGES=(
  qemu-system-x86
  qemu-system-common
  qemu-system-data
  libcapstone4
  libfdt1
  libslirp0
  libvirglrenderer1
  liburing2
  libpmem1
  libbpf1
  libvdeplug2
  librdmacm1
  libibverbs1
  libaio1
  libfuse3-3
  libndctl6
  libdaxctl1
  libnl-route-3-200
  libnl-3-200
  seabios
  ipxe-qemu
)

log_info()  { echo -e "${CYN}ℹ${RST}  $*"; }
log_ok()    { echo -e "${GRN}✓${RST}  $*"; }
log_warn()  { echo -e "${YLW}⚠${RST}  $*"; }
log_fail()  { echo -e "${RED}✗${RST}  $*"; }

echo -e "\n${CYN}${BLD}  QEMU Rootless Installer v1.0${RST}"
echo -e "${DIM}  $(uname -s) $(uname -m) | $(nproc) CPUs | $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?') RAM${RST}\n"

# ── Step 1: Prepare ──
echo -e "${BLU}━━━ ${WHT}PREPARE${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
[ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
mkdir -p "$DEB_DIR" "$EXTRACT_DIR" "$BIN_DIR"
log_ok "Directories created at ${BLD}$INSTALL_DIR${RST}"

# ── Step 2: Download ──
echo -e "\n${BLU}━━━ ${WHT}DOWNLOAD${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
downloaded=0
skipped=0
cd "$DEB_DIR"

for pkg in "${PACKAGES[@]}"; do
  printf "  %-30s " "$pkg"
  if apt-get download "$pkg" >/dev/null 2>&1; then
    echo -e "${GRN}✓${RST}"
    ((downloaded++))
  else
    echo -e "${YLW}skip${RST}"
    ((skipped++))
  fi
done

log_info "${GRN}${downloaded}${RST} downloaded, ${YLW}${skipped}${RST} skipped"

# ── Step 3: Extract ──
echo -e "\n${BLU}━━━ ${WHT}EXTRACT${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
count=0

while IFS= read -r deb; do
  if dpkg-deb -x "$deb" "$EXTRACT_DIR" 2>/dev/null; then
    ((count++))
  fi
done < <(find "$DEB_DIR" -name '*.deb' -type f 2>/dev/null)

log_ok "Extracted ${BLD}${count}${RST} packages"

# ── Step 4: Wrapper ──
echo -e "\n${BLU}━━━ ${WHT}WRAPPER${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
qemu_bin=$(find "$EXTRACT_DIR" -name 'qemu-system-x86_64' -type f 2>/dev/null | head -1)

if [ -z "$qemu_bin" ]; then
  log_fail "qemu-system-x86_64 not found!"
  exit 1
fi

lib_dirs=""
for d in "$EXTRACT_DIR/usr/lib/x86_64-linux-gnu" "$EXTRACT_DIR/lib/x86_64-linux-gnu" "$EXTRACT_DIR/usr/lib"; do
  [ -d "$d" ] && lib_dirs="$d:$lib_dirs"
done
lib_dirs="${lib_dirs%:}"

cat > "$BIN_DIR/qemu-system-x86_64" << WRAPPER
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${lib_dirs}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$qemu_bin" "\$@"
WRAPPER
chmod +x "$BIN_DIR/qemu-system-x86_64"
log_ok "Wrapper: ${BLD}$BIN_DIR/qemu-system-x86_64${RST}"

# ── Step 5: Verify ──
echo -e "\n${BLU}━━━ ${WHT}VERIFY${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
if ver=$("$BIN_DIR/qemu-system-x86_64" --version 2>&1 | head -1); then
  log_ok "${GRN}${BLD}$ver${RST}"
  "$BIN_DIR/qemu-system-x86_64" -machine help 2>/dev/null | head -3 | while read -r l; do
    echo -e "  ${DIM}$l${RST}"
  done
else
  log_fail "Verification failed"
  exit 1
fi

# ── Done ──
elapsed=$(( $(date +%s) - START_TIME ))
disk=$(du -sh "$INSTALL_DIR" | cut -f1)
echo -e "\n${GRN}╔══════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║${RST}  ${WHT}${BLD}🏆 Installation Complete!${RST}                    ${GRN}║${RST}"
echo -e "${GRN}║${RST}  Disk: ${BLD}${disk}${RST}  Time: ${BLD}${elapsed}s${RST}$(printf '%*s' $((24 - ${#disk} - ${#elapsed})) '')${GRN}║${RST}"
echo -e "${GRN}╚══════════════════════════════════════════════╝${RST}"
echo -e "\n${WHT}# Run:${RST}"
echo -e "${CYN}$BIN_DIR/qemu-system-x86_64 --version${RST}"
echo -e "\n${WHT}# Add to PATH:${RST}"
echo -e "${CYN}export PATH=\"$BIN_DIR:\$PATH\"${RST}"
echo -e "\n${WHT}# Boot image:${RST}"
echo -e "${CYN}$BIN_DIR/qemu-system-x86_64 -m 512 -nographic -hda disk.img${RST}\n"
