#!/usr/bin/env bash
set -uo pipefail

RST='\033[0m'; BLD='\033[1m'; RED='\033[1;31m'; GRN='\033[1;32m'
YLW='\033[1;33m'; BLU='\033[1;34m'; CYN='\033[1;36m'; WHT='\033[1;37m'; DIM='\033[2m'

DIR="${1:-$HOME/qemu-local}"
START=$(date +%s)

echo -e "\n${CYN}${BLD}  QEMU Rootless Installer v1.1${RST}"
echo -e "${DIM}  $(uname -sm) | $(nproc) CPUs | $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo '?') RAM${RST}\n"

# ── Clean ──
echo -e "${BLU}━━━ ${WHT}PREPARE${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
[ -d "$DIR" ] && rm -rf "$DIR"
mkdir -p "$DIR/debs" "$DIR/extracted" "$DIR/bin"
echo -e "${GRN}✓${RST}  Directories ready"

# ── Update apt cache ──
echo -e "\n${BLU}━━━ ${WHT}UPDATE APT CACHE${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
if apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list -o Dir::Etc::sourceparts=- 2>/dev/null; then
  echo -e "${GRN}✓${RST}  Cache updated"
else
  echo -e "${YLW}⚠${RST}  Cache update failed, trying with existing cache..."
fi

# ── Download ──
echo -e "\n${BLU}━━━ ${WHT}DOWNLOAD${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ok=0; fail=0
cd "$DIR/debs"

for pkg in \
  qemu-system-x86 qemu-system-common qemu-system-data \
  libcapstone4 libfdt1 libslirp0 libvirglrenderer1 liburing2 \
  libpmem1 libbpf1 libbpf0 libvdeplug2 librdmacm1 libibverbs1 \
  libaio1 libfuse3-3 libndctl6 libdaxctl1 libnl-route-3-200 \
  libnl-3-200 seabios ipxe-qemu
do
  printf "  %-30s " "$pkg"
  if apt-get download "$pkg" >/dev/null 2>&1; then
    echo -e "${GRN}✓${RST}"
    ((ok++))
  else
    echo -e "${YLW}skip${RST}"
    ((fail++))
  fi
done

echo -e "\n  ${GRN}${ok}${RST} downloaded, ${YLW}${fail}${RST} skipped"

# ── Check có file nào tải được không ──
deb_count=$(find "$DIR/debs" -name '*.deb' -type f 2>/dev/null | wc -l)
if [ "$deb_count" -eq 0 ]; then
  echo -e "\n${RED}✗  No packages downloaded!${RST}"
  echo -e "${YLW}  Possible fixes:${RST}"
  echo -e "  1. Run: ${BLD}apt-get update${RST} (may need sudo)"
  echo -e "  2. Check /etc/apt/sources.list has valid repos"
  echo -e "  3. Check internet connectivity: ${BLD}curl -s http://deb.debian.org${RST}"
  exit 1
fi

# ── Extract ──
echo -e "\n${BLU}━━━ ${WHT}EXTRACT${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ext=0
while IFS= read -r deb; do
  if dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null; then
    ((ext++))
  fi
done < <(find "$DIR/debs" -name '*.deb' -type f 2>/dev/null)
echo -e "${GRN}✓${RST}  Extracted ${BLD}${ext}${RST} packages"

# ── Find binary ──
echo -e "\n${BLU}━━━ ${WHT}SETUP${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
qemu_bin=$(find "$DIR/extracted" -name 'qemu-system-x86_64' -type f 2>/dev/null | head -1)
if [ -z "$qemu_bin" ]; then
  echo -e "${RED}✗  qemu-system-x86_64 not found in extracted packages!${RST}"
  exit 1
fi
echo -e "${GRN}✓${RST}  Binary: ${DIM}$qemu_bin${RST}"

# ── Build LD_LIBRARY_PATH ──
lp=""
for d in \
  "$DIR/extracted/usr/lib/x86_64-linux-gnu" \
  "$DIR/extracted/lib/x86_64-linux-gnu" \
  "$DIR/extracted/usr/lib"
do
  [ -d "$d" ] && lp="$d:$lp"
done
lp="${lp%:}"

# ── Create wrapper ──
cat > "$DIR/bin/qemu-system-x86_64" << WEOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${lp}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$qemu_bin" "\$@"
WEOF
chmod +x "$DIR/bin/qemu-system-x86_64"
echo -e "${GRN}✓${RST}  Wrapper: ${BLD}$DIR/bin/qemu-system-x86_64${RST}"

# ── Verify ──
echo -e "\n${BLU}━━━ ${WHT}VERIFY${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

if ver=$("$DIR/bin/qemu-system-x86_64" --version 2>&1); then
  echo -e "${GRN}✓${RST}  $(echo "$ver" | head -1)"
  echo ""
  "$DIR/bin/qemu-system-x86_64" -machine help 2>/dev/null | head -3 | while read -r l; do
    echo -e "  ${DIM}$l${RST}"
  done
else
  echo -e "${RED}✗  Failed!${RST}"
  echo "$ver" 2>/dev/null

  # ── Auto-fix: tìm thêm missing libs ──
  echo -e "\n${YLW}⚠  Attempting auto-fix: scanning missing libs...${RST}"
  missing=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)

  if [ -n "$missing" ]; then
    echo -e "${YLW}  Missing libs:${RST}"
    echo "$missing" | while read -r lib; do echo -e "    ${RED}$lib${RST}"; done

    echo -e "\n${CYN}  Searching for packages...${RST}"
    cd "$DIR/debs"
    for lib in $missing; do
      pkg=$(apt-cache search "$lib" 2>/dev/null | head -1 | awk '{print $1}')
      if [ -n "$pkg" ]; then
        printf "  %-30s " "$pkg"
        if apt-get download "$pkg" >/dev/null 2>&1; then
          echo -e "${GRN}✓${RST}"
        else
          echo -e "${YLW}skip${RST}"
        fi
      fi
    done

    # Re-extract
    while IFS= read -r deb; do
      dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null
    done < <(find "$DIR/debs" -name '*.deb' -type f 2>/dev/null)

    # Rebuild LD_LIBRARY_PATH
    lp=""
    for d in \
      "$DIR/extracted/usr/lib/x86_64-linux-gnu" \
      "$DIR/extracted/lib/x86_64-linux-gnu" \
      "$DIR/extracted/usr/lib"
    do
      [ -d "$d" ] && lp="$d:$lp"
    done
    lp="${lp%:}"

    # Rewrite wrapper
    cat > "$DIR/bin/qemu-system-x86_64" << WEOF2
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${lp}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$qemu_bin" "\$@"
WEOF2
    chmod +x "$DIR/bin/qemu-system-x86_64"

    echo -e "\n${CYN}  Retrying...${RST}"
    if ver2=$("$DIR/bin/qemu-system-x86_64" --version 2>&1); then
      echo -e "${GRN}✓${RST}  $(echo "$ver2" | head -1)"
    else
      echo -e "${RED}✗  Still failing. Missing libs on this system.${RST}"
      LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" || true
      exit 1
    fi
  else
    exit 1
  fi
fi

# ── Done ──
elapsed=$(( $(date +%s) - START ))
disk=$(du -sh "$DIR" 2>/dev/null | cut -f1)
echo -e "\n${GRN}╔════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║  🏆 Install OK!  ${RST}${BLD}${disk}${RST} in ${BLD}${elapsed}s${RST}$(printf '%*s' $((16 - ${#disk} - ${#elapsed})) '')${GRN}║${RST}"
echo -e "${GRN}╚════════════════════════════════════════════╝${RST}"
echo -e "\n${WHT}Run:${RST}  $DIR/bin/qemu-system-x86_64 --version"
echo -e "${WHT}PATH:${RST} export PATH=\"$DIR/bin:\$PATH\"\n"
