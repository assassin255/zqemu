#!/usr/bin/env bash
set -e

silent() {
  "$@" > /dev/null 2>&1
}

ask() {
  read -rp "$1" ans
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then
    echo "$2"
  else
    echo "$ans"
  fi
}

# Fix Python apt_pkg issue (Ubuntu 22.04)
if [ -f /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so ] && \
   [ ! -f /usr/lib/python3/dist-packages/apt_pkg.so ]; then
    sudo ln -sf /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so \
        /usr/lib/python3/dist-packages/apt_pkg.so
fi

choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không ? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
  if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    echo "⚡ QEMU ULTRA đã tồn tại — skip build"
    export PATH="/opt/qemu-optimized/bin:$PATH"
  else
    echo "🚀 Đang Tải Các Apt Cần Thiết..."
    echo "⚠️ Nếu lỗi hãy thử dùng apt install sudo"

    OS_ID="$(. /etc/os-release && echo "$ID")"
    OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

    sudo apt update
    sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv \
        python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config \
        meson aria2 ovmf qemu-utils

    if [[ "$OS_ID" == "ubuntu" ]]; then
      echo "🔥 Detect Ubuntu → Cài LLVM 21"
      wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
      sudo ./llvm.sh 21
      LLVM_VER=21
      sudo apt install -y llvm-$LLVM_VER-tools 2>/dev/null || true
    elif [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
      LLVM_VER=19
      sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
          llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
    else
      LLVM_VER=15
      sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
          llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
    fi

    export CC="clang-$LLVM_VER"
    export CXX="clang++-$LLVM_VER"
    export LD="lld-$LLVM_VER"
    echo "🔎 Compiler: $CC"

    # Check glib version
    GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
    if [ "$(printf '%s\n' "$GLIB_VER" "2.66" | sort -V | head -n1)" != "2.66" ]; then
      echo "⚠️ glib $GLIB_VER quá cũ, đang build glib 2.76..."
      sudo apt install -y libffi-dev gettext
      cd /tmp && wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
      tar xf glib-2.76.6.tar.xz && cd glib-2.76.6
      meson setup build --prefix=/usr/local && ninja -C build && sudo ninja -C build install
      export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
      export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH"
      echo "✅ glib mới: $(pkg-config --modversion glib-2.0)"
    else
      echo "✅ glib đủ yêu cầu: $GLIB_VER"
    fi

    echo "=== [2/6] Cloning QEMU 10.2.1 ==="
    rm -rf /tmp/qemu-src /tmp/qemu-build
    cd /tmp
    silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

    echo "=== [3/6] V12.5 Patches (50 total) ==="
    cd /tmp/qemu-src

    echo "  --- Hot Path Annotations (44) ---"
    sed -i '/^int tcg_gen_code(TCGContext \*s, TranslationBlock \*tb/i\/* V10 */ __attribute__((hot, optimize("O3")))' tcg/tcg.c
    sed -i '/^static void tcg_reg_alloc_op(TCGContext \*s/i\/* V10 */ __attribute__((hot, flatten))' tcg/tcg.c
    sed -i '/^static void tcg_reg_alloc_mov(TCGContext \*s/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static TCGReg tcg_reg_alloc(TCGContext \*s, TCGRegSet required_regs/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static void tcg_reg_alloc_call(TCGContext \*s, TCGOp \*op)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static void tcg_reg_alloc_dup(TCGContext \*s/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static void temp_load(TCGContext \*s, TCGTemp \*ts, TCGRegSet desired/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static void temp_sync(TCGContext \*s, TCGTemp \*ts, TCGRegSet allocated/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static void temp_save(TCGContext \*s, TCGTemp \*ts, TCGRegSet allocated/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^static int tcg_out_ldst_finalize(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^TranslationBlock \*tcg_tb_alloc(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    sed -i '/^void tcg_func_start(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
    echo "    tcg.c: 12"

    sed -i '/^void tcg_optimize(TCGContext \*s)/i\/* V10 */ __attribute__((hot, optimize("O3")))' tcg/optimize.c
    sed -i '/^static bool tcg_opt_gen_mov(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static bool tcg_opt_gen_movi(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static bool finish_folding(OptContext \*ctx, TCGOp \*op)/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static void copy_propagate(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static void init_arguments(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static bool fold_brcond(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    sed -i '/^static int do_constant_folding_cond(TCGType type/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
    echo "    optimize.c: 8"

    sed -i '/^void tcg_gen_exit_tb(const TranslationBlock \*tb/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
    sed -i '/^void tcg_gen_goto_tb(unsigned idx)/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
    sed -i '/^void tcg_gen_lookup_and_goto_ptr(void)/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
    echo "    tcg-op.c: 3"

    sed -i '/^int cpu_exec(CPUState \*cpu)/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
    sed -i 's/static inline TranslationBlock \*tb_lookup(/static inline __attribute__((always_inline)) TranslationBlock *tb_lookup(/' accel/tcg/cpu-exec.c
    sed -i '/^static bool tb_lookup_cmp(const void \*p/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
    sed -i '/^static TranslationBlock \*tb_htable_lookup/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
    sed -i '/^static inline void cpu_loop_exec_tb/i\/* V10 */ __attribute__((hot, flatten))' accel/tcg/cpu-exec.c
    sed -i 's/static inline void tb_add_jump(/static inline __attribute__((always_inline)) void tb_add_jump(/' accel/tcg/cpu-exec.c
    sed -i 's/static inline bool cpu_handle_interrupt(/static inline __attribute__((always_inline)) bool cpu_handle_interrupt(/' accel/tcg/cpu-exec.c
    sed -i 's/static inline bool cpu_handle_exception(/static inline __attribute__((always_inline)) bool cpu_handle_exception(/' accel/tcg/cpu-exec.c
    sed -i 's/if (\*tb_exit != TB_EXIT_REQUESTED)/if (__builtin_expect(*tb_exit != TB_EXIT_REQUESTED, 1))/' accel/tcg/cpu-exec.c
    sed -i 's/if (phys_pc == -1) {/if (__builtin_expect(phys_pc == -1, 0)) {/' accel/tcg/cpu-exec.c
    sed -i 's/if (tb == NULL) {/if (__builtin_expect(tb == NULL, 0)) {/' accel/tcg/cpu-exec.c
    echo "    cpu-exec.c: 11"

    sed -i '1i\/* V10 - TLB hot path */' accel/tcg/cputlb.c
    sed -i '/^static bool victim_tlb_hit/i\__attribute__((hot, flatten))' accel/tcg/cputlb.c
    sed -i 's/static inline bool tlb_hit(uint64_t/static inline __attribute__((always_inline)) bool tlb_hit(uint64_t/' accel/tcg/cputlb.c
    sed -i 's/static inline bool tlb_hit_page(uint64_t/static inline __attribute__((always_inline)) bool tlb_hit_page(uint64_t/' accel/tcg/cputlb.c
    sed -i 's/static inline uintptr_t tlb_index(/static inline __attribute__((always_inline)) uintptr_t tlb_index(/' accel/tcg/cputlb.c
    sed -i 's/static inline CPUTLBEntry \*tlb_entry(/static inline __attribute__((always_inline)) CPUTLBEntry *tlb_entry(/' accel/tcg/cputlb.c
    sed -i 's/static inline uint64_t tlb_read_idx(/static inline __attribute__((always_inline)) uint64_t tlb_read_idx(/' accel/tcg/cputlb.c
    sed -i '/^static bool tlb_fill_align(/i\/* V10 */ __attribute__((hot))' accel/tcg/cputlb.c
    sed -i '/^void tlb_set_page_full(/i\/* V10 */ __attribute__((hot))' accel/tcg/cputlb.c
    sed -i 's/static inline void copy_tlb_helper_locked(/static inline __attribute__((always_inline)) void copy_tlb_helper_locked(/' accel/tcg/cputlb.c
    echo "    cputlb.c: 9"

    sed -i '/^TranslationBlock \*tb_gen_code(CPUState \*cpu/i\/* V10 */ __attribute__((hot))' accel/tcg/translate-all.c
    sed -i '/^static bool tb_cmp(const void \*ap/i\/* V10 */ __attribute__((hot))' accel/tcg/tb-maint.c
    sed -i '/^void translator_loop(CPUState \*cpu/i\/* V10 */ __attribute__((hot))' accel/tcg/translator.c
    echo "    translate-all + tb-maint + translator: 3"

    echo "  --- Fast DBT Tuning (6) ---"
    sed -i 's/#define TB_JMP_CACHE_BITS 12/#define TB_JMP_CACHE_BITS 13/' accel/tcg/tb-jmp-cache.h
    sed -i 's/#define CPU_TEMP_BUF_NLONGS 128/#define CPU_TEMP_BUF_NLONGS 256/' include/tcg/tcg.h
    sed -i 's/#define TCG_MAX_TEMPS 512/#define TCG_MAX_TEMPS 1024/' include/tcg/tcg.h
    echo "  ✅ Total: 50 patches applied!"

    echo "=== [4/6] Configure ==="
    BASE="-O3 -march=native -mtune=native -pipe -fno-strict-aliasing"
    BASE="$BASE -fmerge-all-constants -fno-semantic-interposition -fno-plt"
    BASE="$BASE -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables"
    BASE="$BASE -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG"
    POLLY="-mllvm -polly -mllvm -polly-vectorizer=stripmine"
    INLINE="-mllvm -inline-threshold=500 -mllvm -inlinehint-threshold=1000"

    AVAIL_GB=$(df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}')
    if [ "$AVAIL_GB" -ge 40 ]; then
      LTO_MODE="full"
    else
      LTO_MODE="thin"
      echo "[!] Disk ${AVAIL_GB}GB → LTO=thin"
    fi

    FINAL_CFLAGS="$BASE $POLLY $INLINE -flto=$LTO_MODE"
    FINAL_LDFLAGS="-fuse-ld=lld -flto=$LTO_MODE -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

    mkdir -p /tmp/qemu-build && cd /tmp/qemu-build
    echo "🔁 Đang Biên Dịch..."
    ../qemu-src/configure \
        --prefix=/opt/qemu-optimized \
        --target-list=x86_64-softmmu \
        --enable-tcg --enable-slirp --enable-coroutine-pool --enable-lto \
        --disable-kvm --disable-mshv --disable-xen \
        --disable-gtk --disable-sdl --disable-spice --disable-vnc \
        --disable-plugins --disable-debug-info --disable-docs --disable-werror \
        --disable-fdt --disable-vdi --disable-vvfat --disable-cloop --disable-dmg \
        --disable-pa --disable-alsa --disable-oss --disable-jack \
        --disable-gnutls --disable-smartcard --disable-libusb \
        --disable-seccomp --disable-modules \
        CC="$CC" CXX="$CXX" \
        CFLAGS="$FINAL_CFLAGS" CXXFLAGS="$FINAL_CFLAGS" LDFLAGS="$FINAL_LDFLAGS"

    echo "🕧 QEMU đang được build vui lòng đợi..."
    echo "💣 Nếu trong quá trình build bị lỗi hãy thử ulimit -n 84857"
    ulimit -n 65535 2>/dev/null || true
    ninja -j"$(nproc)" qemu-system-x86_64 qemu-img

    echo "=== [6/6] Installing ==="
    sudo mkdir -p /opt/qemu-optimized/bin /opt/qemu-optimized/share/qemu
    sudo cp qemu-system-x86_64 qemu-img /opt/qemu-optimized/bin/
    sudo cp /tmp/qemu-src/pc-bios/*.bin /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.rom /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.img /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.fd  /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    export PATH="/opt/qemu-optimized/bin:$PATH"
    rm -rf /tmp/qemu-build /tmp/qemu-src

    qemu-system-x86_64 --version
    echo "🔥 QEMU LLVM đã build xong"
  fi
else
  echo "⚡ Bỏ qua build QEMU."
  if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    export PATH="/opt/qemu-optimized/bin:$PATH"
  else
    echo "[!] QEMU chưa build. Cài bản hệ thống..."
    sudo apt update && sudo apt install -y qemu-system-x86 qemu-utils aria2 ovmf
  fi
fi

echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER"
echo "════════════════════════════════════"
echo "1️⃣  Tạo Windows VM"
echo "2️⃣  Quản Lý Windows VM"
echo "════════════════════════════════════"
read -rp "👉 Nhập lựa chọn [1-2]: " main_choice

case "$main_choice" in
2)
  echo ""
  echo -e "\033[1;36m🚀 ===== MANAGE RUNNING VM ===== 🚀\033[0m"
  VM_LIST=$(pgrep -f '^qemu-system' || true)
  if [[ -z "$VM_LIST" ]]; then
    echo "❌ Không có VM nào đang chạy"
  else
    for pid in $VM_LIST; do
      cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
      vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
      ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
      cpu=$(ps -p $pid -o %cpu= 2>/dev/null)
      mem=$(ps -p $pid -o %mem= 2>/dev/null)
      echo -e "🆔 PID: \033[1;33m$pid\033[0m  |  🔢 vCPU: \033[1;34m${vcpu}\033[0m  |  📦 RAM: \033[1;34m${ram}\033[0m  |  🧠 CPU: \033[1;32m${cpu}%\033[0m  |  💾 MEM: \033[1;35m${mem}%\033[0m"
    done
  fi
  echo -e "\033[1;36m==================================\033[0m"
  read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
  if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
    kill "$kill_pid" 2>/dev/null || true
    echo "✅ Đã gửi tín hiệu tắt VM PID $kill_pid"
  fi
  exit 0
  ;;
esac

echo ""
echo "🪟 Chọn phiên bản Windows muốn tải:"
echo "1️⃣ Windows Server 2012 R2 x64"
echo "2️⃣ Windows Server 2022 x64"
echo "3️⃣ Windows 11 LTSB x64"
echo "4️⃣ Windows 10 LTSB 2015 x64"
echo "5️⃣ Windows 10 LTSC 2023 x64"
read -rp "👉 Nhập số [1-5]: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022"; WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"; USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB"; WIN_URL="https://archive.org/download/win_20260203/win.img"; USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015"; WIN_URL="https://archive.org/download/win_20260208/win.img"; USE_UEFI="no" ;;
5) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img"; USE_UEFI="no" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin"; RDP_PASS="Tam255Z" ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

echo "🪟 Đang Tải $WIN_NAME..."
if [[ ! -f win.img ]]; then
  silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"

QIMG=$(command -v qemu-img 2>/dev/null || echo "/opt/qemu-optimized/bin/qemu-img")
if ! command -v "$QIMG" &>/dev/null; then
  sudo apt install -y qemu-utils
  QIMG=$(command -v qemu-img)
fi
silent $QIMG resize win.img "+${extra_gb}G"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')

# FIX: Removed invtsc=on (TCG doesn't support → VM crash)
cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "⚙ CPU core (default 4): " cpu_core
cpu_core="${cpu_core:-4}"

read -rp "💾 RAM GB (default 4): " ram_size
ram_size="${ram_size:-4}"

if [[ "$win_choice" == "4" ]]; then
  NET_DEVICE="-device e1000e,netdev=n0"
else
  NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi

BIOS_OPT=""
if [[ "$USE_UEFI" == "yes" ]]; then
  for bp in /opt/qemu-optimized/share/qemu/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
    [ -f "$bp" ] && BIOS_OPT="-bios $bp" && break
  done
fi

QBIN=$(command -v qemu-system-x86_64 2>/dev/null || echo "/opt/qemu-optimized/bin/qemu-system-x86_64")

echo "⌛ Đang Tạo VM với cấu hình bạn đã nhập vui lòng đợi..."

$QBIN \
    -L /opt/qemu-optimized/share/qemu \
    -L /usr/share/qemu \
    -L /usr/lib/ipxe/qemu \
    -machine q35,hpet=off \
    -cpu "$cpu_model" \
    -smp "$cpu_core",sockets=1,cores="$cpu_core",threads=1 \
    -m "${ram_size}G" \
    -accel tcg,thread=multi,tb-size=2097152 \
    -rtc base=localtime \
    $BIOS_OPT \
    -drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
    $NET_DEVICE \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -nodefaults \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
    -no-user-config \
    -display none \
    -vga virtio \
    -daemonize \
    2>/tmp/qemu_error.log || true

sleep 3

if pgrep -f qemu-system-x86_64 > /dev/null; then
  echo "✅ VM đã khởi động thành công!"
else
  echo "❌ VM không khởi động được!"
  echo "📋 Error log:"
  cat /tmp/qemu_error.log
  exit 1
fi

use_rdp=$(ask "🛰️ Tiếp tục mở port để kết nối đến VM? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
  silent wget -q https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
  silent tar -xzf kami-tunnel-linux-amd64.tar.gz
  silent chmod +x kami-tunnel
  silent sudo apt install -y tmux

  tmux kill-session -t kami 2>/dev/null || true
  tmux new-session -d -s kami "./kami-tunnel 3389"
  sleep 4

  PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)

  echo ""
  echo "══════════════════════════════════════════════"
  echo "🚀 WINDOWS VM DEPLOYED SUCCESSFULLY"
  echo "══════════════════════════════════════════════"
  echo "🪟 OS          : $WIN_NAME"
  echo "⚙ CPU Cores   : $cpu_core"
  echo "💾 RAM         : ${ram_size} GB"
  echo "🧠 CPU Host    : $cpu_host"
  echo "──────────────────────────────────────────────"
  echo "📡 RDP Address : $PUBLIC"
  echo "👤 Username    : $RDP_USER"
  echo "🔑 Password    : $RDP_PASS"
  echo "══════════════════════════════════════════════"
  echo "🟢 Status      : RUNNING"
  echo "⏱ GUI Mode   : Headless / RDP"
  echo "══════════════════════════════════════════════"
else
  echo ""
  echo "══════════════════════════════════════════════"
  echo "🚀 VM RUNNING (no tunnel)"
  echo "══════════════════════════════════════════════"
  echo "🪟 OS          : $WIN_NAME"
  echo "⚙ CPU Cores   : $cpu_core"
  echo "💾 RAM         : ${ram_size} GB"
  echo "📡 RDP         : localhost:3389"
  echo "👤 Username    : $RDP_USER"
  echo "🔑 Password    : $RDP_PASS"
  echo "══════════════════════════════════════════════"
fi
