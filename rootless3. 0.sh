#!/usr/bin/env bash
set -uo pipefail

RST='\033[0m'; BLD='\033[1m'; RED='\033[1;31m'; GRN='\033[1;32m'
YLW='\033[1;33m'; BLU='\033[1;34m'; CYN='\033[1;36m'; WHT='\033[1;37m'; DIM='\033[2m'

DIR="${1:-$HOME/qemu-local}"
START=$(date +%s)

echo -e "\n${CYN}${BLD}  QEMU Rootless Installer v3.0 (Ubuntu 22.04)${RST}"
echo -e "${DIM}  $(uname -sm) | $(nproc) CPUs | $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo '?') RAM${RST}\n"

[ -d "$DIR" ] && rm -rf "$DIR"
mkdir -p "$DIR/debs" "$DIR/extracted" "$DIR/bin"
echo -e "${GRN}✓${RST}  Directories ready"

cd "$DIR/debs"

# ── Download helper ──
grab() {
  local name="$1" url="$2" fname="${1}.deb"
  printf "  %-25s " "$name"
  # Try apt first
  if apt-get download "$name" >/dev/null 2>&1; then
    echo -e "${GRN}✓${RST} ${DIM}(apt)${RST}"; return 0
  fi
  # Fallback: direct URL
  if curl -sfL --connect-timeout 10 -o "$fname" "$url" 2>/dev/null \
     && [ -s "$fname" ] \
     && head -c 4 "$fname" | grep -q '!<arch'; then
    echo -e "${GRN}✓${RST} ${DIM}(url)${RST}"; return 0
  fi
  rm -f "$fname"
  echo -e "${YLW}skip${RST}"; return 1
}

echo -e "\n${BLU}━━━ ${WHT}DOWNLOAD${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ok=0; fail=0
S="http://security.ubuntu.com/ubuntu/pool/main"
U="http://archive.ubuntu.com/ubuntu/pool"

grab qemu-system-x86    "$S/q/qemu/qemu-system-x86_6.2+dfsg-2ubuntu6.27_amd64.deb"       && ((ok++)) || ((fail++))
grab qemu-system-common "$S/q/qemu/qemu-system-common_6.2+dfsg-2ubuntu6.27_amd64.deb"    && ((ok++)) || ((fail++))
grab qemu-system-data   "$S/q/qemu/qemu-system-data_6.2+dfsg-2ubuntu6.27_all.deb"        && ((ok++)) || ((fail++))
grab libcapstone4       "$U/main/c/capstone/libcapstone4_4.0.2-5_amd64.deb"               && ((ok++)) || ((fail++))
grab libfdt1            "$U/main/d/dtc/libfdt1_1.6.1-1_amd64.deb"                         && ((ok++)) || ((fail++))
grab libslirp0          "$U/main/libs/libslirp/libslirp0_4.6.1-1build1_amd64.deb"         && ((ok++)) || ((fail++))
grab libvirglrenderer1  "$U/universe/v/virglrenderer/libvirglrenderer1_0.9.1-3_amd64.deb"  && ((ok++)) || ((fail++))
grab libpmem1           "$U/universe/p/pmdk/libpmem1_1.11.1-3build1_amd64.deb"             && ((ok++)) || ((fail++))
grab libvdeplug2        "$U/universe/v/vde2/libvdeplug2_2.3.2+r586-7_amd64.deb"            && ((ok++)) || ((fail++))
grab librdmacm1         "$U/main/r/rdma-core/librdmacm1_39.0-1_amd64.deb"                 && ((ok++)) || ((fail++))
grab libibverbs1        "$U/main/r/rdma-core/libibverbs1_39.0-1_amd64.deb"                 && ((ok++)) || ((fail++))
grab libaio1            "$U/main/liba/libaio/libaio1_0.3.112-13build1_amd64.deb"           && ((ok++)) || ((fail++))
grab libfuse3-3         "$U/main/f/fuse3/libfuse3-3_3.10.5-1build1_amd64.deb"              && ((ok++)) || ((fail++))
grab libndctl6          "$U/main/n/ndctl/libndctl6_72.1-1_amd64.deb"                       && ((ok++)) || ((fail++))
grab libdaxctl1         "$U/main/n/ndctl/libdaxctl1_72.1-1_amd64.deb"                      && ((ok++)) || ((fail++))
grab libnl-route-3-200  "$U/main/libn/libnl3/libnl-route-3-200_3.5.0-0.1_amd64.deb"       && ((ok++)) || ((fail++))
grab libnl-3-200        "$U/main/libn/libnl3/libnl-3-200_3.5.0-0.1_amd64.deb"             && ((ok++)) || ((fail++))
grab libpixman-1-0      "$U/main/p/pixman/libpixman-1-0_0.40.0-1ubuntu0.22.04.1_amd64.deb" && ((ok++)) || ((fail++))
grab liburing2          "$U/main/libu/liburing/liburing2_2.1-2build1_amd64.deb"             && ((ok++)) || ((fail++))
grab seabios            "$U/universe/s/seabios/seabios_1.15.0-1_all.deb"                    && ((ok++)) || ((fail++))
grab ipxe-qemu          "$U/main/i/ipxe/ipxe-qemu_1.21.1+git-20220113.fbbdc3926-0ubuntu2_all.deb" && ((ok++)) || ((fail++))

echo -e "\n  ${GRN}${ok}${RST} ok, ${YLW}${fail}${RST} skipped"

# ── Extract ──
echo -e "\n${BLU}━━━ ${WHT}EXTRACT${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ext=0
while IFS= read -r deb; do
  dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null && ((ext++))
done < <(find "$DIR/debs" -maxdepth 1 -name '*.deb' -type f)
echo -e "${GRN}✓${RST}  Extracted ${BLD}${ext}${RST} packages"

# ── Find binary ──
echo -e "\n${BLU}━━━ ${WHT}SETUP${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
qemu_bin=$(find "$DIR/extracted" -name 'qemu-system-x86_64' -type f 2>/dev/null | head -1)
if [ -z "$qemu_bin" ]; then
  echo -e "${RED}✗  qemu-system-x86_64 not found!${RST}"
  exit 1
fi
echo -e "${GRN}✓${RST}  Binary: ${DIM}$qemu_bin${RST}"

# ── Lib path ──
lp=""
for d in "$DIR/extracted/usr/lib/x86_64-linux-gnu" "$DIR/extracted/lib/x86_64-linux-gnu" "$DIR/extracted/usr/lib" "$DIR/extracted/lib"; do
  [ -d "$d" ] && lp="$d:$lp"
done
lp="${lp%:}"

# ── Auto-fix missing libs ──
missing=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)
if [ -n "$missing" ]; then
  echo -e "${YLW}⚠${RST}  Missing libs detected, auto-fixing..."
  cd "$DIR/debs"
  for lib in $missing; do
    pkg=$(apt-cache search "$(echo "$lib" | sed 's/\.so.*//')" 2>/dev/null | grep "^lib" | head -1 | awk '{print $1}')
    [ -n "$pkg" ] && apt-get download "$pkg" >/dev/null 2>&1 && echo -e "    ${GRN}✓${RST} $pkg"
  done
  while IFS= read -r deb; do
    dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null
  done < <(find "$DIR/debs" -maxdepth 1 -name '*.deb' -type f)
  lp=""
  for d in "$DIR/extracted/usr/lib/x86_64-linux-gnu" "$DIR/extracted/lib/x86_64-linux-gnu" "$DIR/extracted/usr/lib" "$DIR/extracted/lib"; do
    [ -d "$d" ] && lp="$d:$lp"
  done
  lp="${lp%:}"
fi

# ── Wrapper ──
cat > "$DIR/bin/qemu-system-x86_64" << WEOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${lp}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$qemu_bin" "\$@"
WEOF
chmod +x "$DIR/bin/qemu-system-x86_64"
echo -e "${GRN}✓${RST}  Wrapper created"

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

elapsed=$(( $(date +%s) - START ))
disk=$(du -sh "$DIR" 2>/dev/null | cut -f1)
echo -e "\n${GRN}╔════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║  🏆 Install OK!  ${RST}${BLD}${disk}${RST} in ${BLD}${elapsed}s${RST}$(printf '%*s' $((16 - ${#disk} - ${#elapsed})) '')${GRN}║${RST}"
echo -e "${GRN}╚════════════════════════════════════════════╝${RST}"
echo -e "\n${WHT}Run:${RST}   $DIR/bin/qemu-system-x86_64 --version"
echo -e "${WHT}PATH:${RST}  export PATH=\"$DIR/bin:\$PATH\"\n"
