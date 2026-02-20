#!/usr/bin/env bash
set -uo pipefail

RST='\033[0m'; BLD='\033[1m'; RED='\033[1;31m'; GRN='\033[1;32m'
YLW='\033[1;33m'; BLU='\033[1;34m'; CYN='\033[1;36m'; WHT='\033[1;37m'; DIM='\033[2m'

DIR="${1:-$HOME/qemu-local}"
START=$(date +%s)

echo -e "\n${CYN}${BLD}  QEMU Rootless Installer v2.0 (Ubuntu 22.04)${RST}"
echo -e "${DIM}  $(uname -sm) | $(nproc) CPUs | $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo '?') RAM${RST}\n"

[ -d "$DIR" ] && rm -rf "$DIR"
mkdir -p "$DIR/debs" "$DIR/extracted" "$DIR/bin"
echo -e "${GRN}✓${RST}  Directories ready"

cd "$DIR/debs"

# ══════════════════════════════════════════════════════════
# Ubuntu 22.04 (Jammy) exact .deb URLs from archive
# ══════════════════════════════════════════════════════════
BASE_U="http://archive.ubuntu.com/ubuntu/pool"
BASE_S="http://security.ubuntu.com/ubuntu/pool"

declare -A DEBS
DEBS=(
  # QEMU core - universe repo (thường không có trong apt mặc định của Jupyter)
  ["qemu-system-x86"]="${BASE_U}/universe/q/qemu/qemu-system-x86_1%3a6.2+dfsg-2ubuntu6.28_amd64.deb"
  ["qemu-system-common"]="${BASE_U}/universe/q/qemu/qemu-system-common_1%3a6.2+dfsg-2ubuntu6.28_amd64.deb"
  ["qemu-system-data"]="${BASE_U}/universe/q/qemu/qemu-system-data_1%3a6.2+dfsg-2ubuntu6.28_all.deb"

  # Libs - main repo
  ["libcapstone4"]="${BASE_U}/main/c/capstone/libcapstone4_4.0.2-5_amd64.deb"
  ["libfdt1"]="${BASE_U}/main/d/dtc/libfdt1_1.6.1-1_amd64.deb"
  ["libslirp0"]="${BASE_U}/main/libs/libslirp/libslirp0_4.6.1-1build1_amd64.deb"
  ["libvirglrenderer1"]="${BASE_U}/universe/v/virglrenderer/libvirglrenderer1_0.9.1-3_amd64.deb"
  ["libpmem1"]="${BASE_U}/universe/p/pmdk/libpmem1_1.11.1-3build1_amd64.deb"
  ["libvdeplug2"]="${BASE_U}/universe/v/vde2/libvdeplug2_2.3.2+r586-7_amd64.deb"
  ["librdmacm1"]="${BASE_U}/main/r/rdma-core/librdmacm1_39.0-1_amd64.deb"
  ["libibverbs1"]="${BASE_U}/main/r/rdma-core/libibverbs1_39.0-1_amd64.deb"
  ["libaio1"]="${BASE_U}/main/liba/libaio/libaio1_0.3.112-13build1_amd64.deb"
  ["libfuse3-3"]="${BASE_U}/main/f/fuse3/libfuse3-3_3.10.5-1build1_amd64.deb"
  ["libndctl6"]="${BASE_U}/main/n/ndctl/libndctl6_72.1-1_amd64.deb"
  ["libdaxctl1"]="${BASE_U}/main/n/ndctl/libdaxctl1_72.1-1_amd64.deb"
  ["libnl-route-3-200"]="${BASE_U}/main/libn/libnl3/libnl-route-3-200_3.5.0-0.1_amd64.deb"
  ["libnl-3-200"]="${BASE_U}/main/libn/libnl3/libnl-3-200_3.5.0-0.1_amd64.deb"
  ["libpixman-1-0"]="${BASE_U}/main/p/pixman/libpixman-1-0_0.40.0-1ubuntu0.22.04.1_amd64.deb"
  ["liburing2"]="${BASE_U}/main/libu/liburing/liburing2_2.1-2build1_amd64.deb"
  ["seabios"]="${BASE_U}/universe/s/seabios/seabios_1.15.0-1_all.deb"
  ["ipxe-qemu"]="${BASE_U}/main/i/ipxe/ipxe-qemu_1.21.1+git-20220113.fbbdc3926-0ubuntu2_all.deb"
)

echo -e "\n${BLU}━━━ ${WHT}DOWNLOAD${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ok=0; fail=0

for name in "${!DEBS[@]}"; do
  url="${DEBS[$name]}"
  fname="${name}.deb"
  printf "  %-25s " "$name"

  # Thử apt-get download trước (nhanh hơn nếu có cache)
  if apt-get download "$name" >/dev/null 2>&1; then
    echo -e "${GRN}✓${RST} ${DIM}(apt)${RST}"
    ((ok++))
  # Fallback: curl trực tiếp từ archive
  elif curl -sfL -o "$fname" "$url" 2>/dev/null && [ -s "$fname" ] && file "$fname" | grep -q "Debian"; then
    echo -e "${GRN}✓${RST} ${DIM}(url)${RST}"
    ((ok++))
  else
    rm -f "$fname"
    echo -e "${YLW}skip${RST}"
    ((fail++))
  fi
done

echo -e "\n  ${GRN}${ok}${RST} downloaded, ${YLW}${fail}${RST} skipped"

# ── Check có tải được gì không ──
deb_count=$(find "$DIR/debs" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l)
if [ "$deb_count" -eq 0 ]; then
  echo -e "\n${RED}✗  Nothing downloaded! Check network.${RST}"
  exit 1
fi

# ── Extract ──
echo -e "\n${BLU}━━━ ${WHT}EXTRACT${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ext=0
while IFS= read -r deb; do
  if dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null; then
    ((ext++))
  fi
done < <(find "$DIR/debs" -maxdepth 1 -name '*.deb' -type f 2>/dev/null)
echo -e "${GRN}✓${RST}  Extracted ${BLD}${ext}${RST} packages"

# ── Find binary ──
echo -e "\n${BLU}━━━ ${WHT}SETUP${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
qemu_bin=$(find "$DIR/extracted" -name 'qemu-system-x86_64' -type f 2>/dev/null | head -1)

if [ -z "$qemu_bin" ]; then
  echo -e "${RED}✗  qemu-system-x86_64 not found!${RST}"
  echo -e "${YLW}  Found files:${RST}"
  find "$DIR/extracted" -name 'qemu-*' -type f 2>/dev/null | head -5
  exit 1
fi
echo -e "${GRN}✓${RST}  Binary: ${DIM}$qemu_bin${RST}"

# ── Lib path ──
lp=""
for d in \
  "$DIR/extracted/usr/lib/x86_64-linux-gnu" \
  "$DIR/extracted/lib/x86_64-linux-gnu" \
  "$DIR/extracted/usr/lib" \
  "$DIR/extracted/lib"
do
  [ -d "$d" ] && lp="$d:$lp"
done
lp="${lp%:}"

# ── Auto-fix missing libs ──
missing=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)
if [ -n "$missing" ]; then
  echo -e "${YLW}⚠${RST}  Missing libs, auto-fixing..."
  cd "$DIR/debs"
  for lib in $missing; do
    pkg=$(apt-cache search "^lib.*$(echo "$lib" | sed 's/\.so.*//' | sed 's/^lib//')" 2>/dev/null | grep "^lib" | head -1 | awk '{print $1}')
    if [ -n "$pkg" ]; then
      printf "    %-20s " "$pkg"
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
  done < <(find "$DIR/debs" -maxdepth 1 -name '*.deb' -type f 2>/dev/null)

  # Rebuild lp
  lp=""
  for d in \
    "$DIR/extracted/usr/lib/x86_64-linux-gnu" \
    "$DIR/extracted/lib/x86_64-linux-gnu" \
    "$DIR/extracted/usr/lib" \
    "$DIR/extracted/lib"
  do
    [ -d "$d" ] && lp="$d:$lp"
  done
  lp="${lp%:}"

  still=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)
  if [ -n "$still" ]; then
    echo -e "${YLW}⚠${RST}  Still missing:"
    echo "$still" | while read -r l; do echo -e "    ${DIM}$l${RST}"; done
  else
    echo -e "${GRN}✓${RST}  All libs resolved"
  fi
fi

# ── Wrapper ──
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
  "$DIR/bin/qemu-system-x86_64" -machine help 2>/dev/null | head -3 | while read -r l; do
    echo -e "  ${DIM}$l${RST}"
  done
else
  echo -e "${RED}✗  Failed:${RST}"
  echo "$ver" 2>/dev/null | head -3
  LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" || true
  exit 1
fi

# ── Done ──
elapsed=$(( $(date +%s) - START ))
disk=$(du -sh "$DIR" 2>/dev/null | cut -f1)
echo -e "\n${GRN}╔════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║  🏆 Install OK!  ${RST}${BLD}${disk}${RST} in ${BLD}${elapsed}s${RST}$(printf '%*s' $((16 - ${#disk} - ${#elapsed})) '')${GRN}║${RST}"
echo -e "${GRN}╚════════════════════════════════════════════╝${RST}"
echo -e "\n${WHT}Run:${RST}   $DIR/bin/qemu-system-x86_64 --version"
echo -e "${WHT}PATH:${RST}  export PATH=\"$DIR/bin:\$PATH\""
echo -e "${WHT}Boot:${RST}  qemu-system-x86_64 -m 512 -nographic -hda disk.img\n"
