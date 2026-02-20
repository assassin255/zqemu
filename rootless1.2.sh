#!/usr/bin/env bash
set -uo pipefail

RST='\033[0m'; BLD='\033[1m'; RED='\033[1;31m'; GRN='\033[1;32m'
YLW='\033[1;33m'; BLU='\033[1;34m'; CYN='\033[1;36m'; WHT='\033[1;37m'; DIM='\033[2m'

DIR="${1:-$HOME/qemu-local}"
START=$(date +%s)

echo -e "\n${CYN}${BLD}  QEMU Rootless Installer v1.2${RST}"
echo -e "${DIM}  $(uname -sm) | $(nproc) CPUs | $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo '?') RAM${RST}"

# ── Detect distro ──
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo -e "${DIM}  $PRETTY_NAME${RST}\n"
else
  PRETTY_NAME="Unknown"
  ID="unknown"
  VERSION_CODENAME=""
  echo -e "${DIM}  Unknown distro${RST}\n"
fi

# ── Clean ──
echo -e "${BLU}━━━ ${WHT}PREPARE${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
[ -d "$DIR" ] && rm -rf "$DIR"
mkdir -p "$DIR/debs" "$DIR/extracted" "$DIR/bin"
echo -e "${GRN}✓${RST}  Directories ready at ${BLD}$DIR${RST}"

# ── Helper: download one package, try multiple names ──
dl_pkg() {
  local names=("$@")
  for name in "${names[@]}"; do
    if apt-get download "$name" >/dev/null 2>&1; then
      echo "$name"
      return 0
    fi
  done
  return 1
}

# ── Helper: download from direct URL ──
dl_url() {
  local url="$1"
  local fname="$2"
  if curl -sL -o "$fname" "$url" 2>/dev/null && [ -s "$fname" ]; then
    return 0
  fi
  rm -f "$fname"
  return 1
}

# ── Try apt-get update (non-fatal) ──
echo -e "\n${BLU}━━━ ${WHT}UPDATE CACHE${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
apt-get update -qq 2>/dev/null && echo -e "${GRN}✓${RST}  Updated" || echo -e "${YLW}⚠${RST}  Skipped (no sudo), using existing cache"

# ── Download ──
echo -e "\n${BLU}━━━ ${WHT}DOWNLOAD${BLU} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
ok=0; fail=0
cd "$DIR/debs"

# Try apt-get download with fallback names
declare -A PKGS=(
  ["qemu-system-x86"]="qemu-system-x86 qemu-system-x86-64"
  ["qemu-system-common"]="qemu-system-common qemu-common"
  ["qemu-system-data"]="qemu-system-data qemu-system-gui qemu-efi"
  ["libcapstone4"]="libcapstone4 libcapstone3"
  ["libfdt1"]="libfdt1"
  ["libslirp0"]="libslirp0"
  ["libvirglrenderer1"]="libvirglrenderer1"
  ["liburing2"]="liburing2 liburing1"
  ["libpmem1"]="libpmem1"
  ["libbpf1"]="libbpf1 libbpf0"
  ["libvdeplug2"]="libvdeplug2"
  ["librdmacm1"]="librdmacm1t64 librdmacm1"
  ["libibverbs1"]="libibverbs1"
  ["libaio1"]="libaio1t64 libaio1"
  ["libfuse3-3"]="libfuse3-3"
  ["libndctl6"]="libndctl6"
  ["libdaxctl1"]="libdaxctl1"
  ["libnl-route-3-200"]="libnl-route-3-200"
  ["libnl-3-200"]="libnl-3-200"
  ["libpixman"]="libpixman-1-0"
  ["seabios"]="seabios"
  ["ipxe-qemu"]="ipxe-qemu ipxe-qemu-256k-compat-efi-roms"
)

qemu_found=false
for key in "${!PKGS[@]}"; do
  IFS=' ' read -ra names <<< "${PKGS[$key]}"
  printf "  %-30s " "$key"
  if got=$(dl_pkg "${names[@]}"); then
    echo -e "${GRN}✓${RST} ${DIM}($got)${RST}"
    ((ok++))
    [[ "$key" == "qemu-system-x86" ]] && qemu_found=true
  else
    echo -e "${YLW}skip${RST}"
    ((fail++))
  fi
done

# ── Fallback: direct .deb download if qemu-system-x86 failed ──
if ! $qemu_found; then
  echo -e "\n${YLW}⚠  qemu-system-x86 not in apt. Trying direct .deb download...${RST}"

  # Detect arch
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

  # Try multiple known URLs
  URLS=(
    "http://ftp.debian.org/debian/pool/main/q/qemu/qemu-system-x86_1%3a7.2+dfsg-7+deb12u18_${ARCH}.deb"
    "http://ftp.debian.org/debian/pool/main/q/qemu/qemu-system-common_1%3a7.2+dfsg-7+deb12u18_${ARCH}.deb"
    "http://ftp.debian.org/debian/pool/main/q/qemu/qemu-system-data_1%3a7.2+dfsg-7+deb12u18_all.deb"
    "http://archive.ubuntu.com/ubuntu/pool/main/q/qemu/qemu-system-x86_1%3a8.2.2+ds-0ubuntu1_${ARCH}.deb"
    "http://archive.ubuntu.com/ubuntu/pool/main/q/qemu/qemu-system-common_1%3a8.2.2+ds-0ubuntu1_${ARCH}.deb"
    "http://archive.ubuntu.com/ubuntu/pool/main/q/qemu/qemu-system-data_1%3a8.2.2+ds-0ubuntu1_all.deb"
  )

  for url in "${URLS[@]}"; do
    fname=$(basename "$url" | sed 's/%3a/:/g')
    # Clean filename
    fname=$(echo "$fname" | sed 's/[^a-zA-Z0-9._-]/_/g')
    printf "  %-55s " "$(echo "$url" | grep -oP 'qemu-system-[^_]+')"
    if dl_url "$url" "$fname"; then
      echo -e "${GRN}✓${RST}"
      ((ok++))
      qemu_found=true
    else
      echo -e "${YLW}skip${RST}"
    fi
  done

  # Also try with apt-cache to find exact version
  if ! $qemu_found; then
    echo -e "\n${CYN}  Searching apt-cache for qemu...${RST}"
    qemu_pkg=$(apt-cache search "qemu-system" 2>/dev/null | grep -E "^qemu-system.*(x86|amd64)" | head -1 | awk '{print $1}')
    if [ -n "$qemu_pkg" ]; then
      printf "  %-30s " "$qemu_pkg"
      if apt-get download "$qemu_pkg" >/dev/null 2>&1; then
        echo -e "${GRN}✓${RST}"
        qemu_found=true
        ((ok++))
      else
        echo -e "${RED}✗${RST}"
      fi
    fi
  fi
fi

echo -e "\n  ${GRN}${ok}${RST} downloaded, ${YLW}${fail}${RST} skipped"

# ── Verify we have something ──
deb_count=$(find "$DIR/debs" -name '*.deb' -type f 2>/dev/null | wc -l)
if [ "$deb_count" -eq 0 ]; then
  echo -e "\n${RED}✗  No packages downloaded at all!${RST}"
  echo -e "  Check: ${BLD}apt-cache search qemu-system${RST}"
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
  echo -e "${RED}✗  qemu-system-x86_64 binary not found!${RST}"
  echo -e "${YLW}  Trying to find any qemu binary...${RST}"
  find "$DIR/extracted" -name 'qemu-*' -type f 2>/dev/null | head -5 | while read -r f; do
    echo -e "  ${DIM}found: $f${RST}"
  done
  echo -e "\n${YLW}  Your distro ($PRETTY_NAME) may use different package names.${RST}"
  echo -e "  Try: ${BLD}apt-cache search qemu-system${RST}"
  exit 1
fi

echo -e "${GRN}✓${RST}  Binary: ${DIM}$qemu_bin${RST}"

# ── Build lib path ──
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

# ── Check for missing libs and auto-fix ──
missing=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)

if [ -n "$missing" ]; then
  echo -e "${YLW}⚠${RST}  Missing shared libraries detected, auto-fixing..."
  cd "$DIR/debs"
  for lib in $missing; do
    # Search which package provides this lib
    pkg=$(apt-cache search "$lib" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -z "$pkg" ]; then
      # Try without .so version
      lib_base=$(echo "$lib" | sed 's/\.so.*//')
      pkg=$(apt-cache search "$lib_base" 2>/dev/null | grep "^lib" | head -1 | awk '{print $1}')
    fi
    if [ -n "$pkg" ]; then
      printf "    %-25s " "$pkg (for $lib)"
      if apt-get download "$pkg" >/dev/null 2>&1; then
        echo -e "${GRN}✓${RST}"
      else
        echo -e "${YLW}skip${RST}"
      fi
    fi
  done

  # Re-extract all
  while IFS= read -r deb; do
    dpkg-deb -x "$deb" "$DIR/extracted" 2>/dev/null
  done < <(find "$DIR/debs" -name '*.deb' -type f 2>/dev/null)

  # Rebuild lib path
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

  # Check again
  still_missing=$(LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" | awk '{print $1}' || true)
  if [ -n "$still_missing" ]; then
    echo -e "${YLW}⚠${RST}  Still missing (may be OK if already on system):"
    echo "$still_missing" | while read -r l; do echo -e "    ${DIM}$l${RST}"; done
  else
    echo -e "${GRN}✓${RST}  All libraries resolved"
  fi
fi

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
  "$DIR/bin/qemu-system-x86_64" -machine help 2>/dev/null | head -3 | while read -r l; do
    echo -e "  ${DIM}$l${RST}"
  done
else
  echo -e "${RED}✗  Verification failed:${RST}"
  echo "$ver" 2>/dev/null | head -3
  echo -e "\n${YLW}Remaining missing libs:${RST}"
  LD_LIBRARY_PATH="$lp" ldd "$qemu_bin" 2>/dev/null | grep "not found" || echo "  (none)"
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
