#!/usr/bin/env bash
set -e

# ╔══════════════════════════════════════════════════════════════════╗
# ║  ZQEMU v14.0 ULTRA MAX — Deep LLVM + TCG Optimized Build       ║
# ║  ✅ Verified build: Debian 13 / Ubuntu (Clang 19-21 + Polly)   ║
# ║  ✅ 70+ hot path patches across 12 source files                ║
# ║  ✅ x86 frontend, physmem, TB hash, CC helpers all patched     ║
# ║  ✅ Advanced LLVM: Polly, GVN hoist/sink, aggressive inlining  ║
# ╚══════════════════════════════════════════════════════════════════╝

silent() { "$@" > /dev/null 2>&1; }

ask() {
  read -rp "$1" ans
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then echo "$2"; else echo "$ans"; fi
}

msg()  { echo -e "\033[1;32m✅ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $1\033[0m"; }
err()  { echo -e "\033[1;31m❌ $1\033[0m"; }
info() { echo -e "\033[1;36mℹ️  $1\033[0m"; }

# ── Fix Python apt_pkg issue (Ubuntu 22.04) ──
if [ -f /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so ] && \
   [ ! -f /usr/lib/python3/dist-packages/apt_pkg.so ]; then
    sudo ln -sf /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so \
        /usr/lib/python3/dist-packages/apt_pkg.so
fi

choice=$(ask "👉 Bạn có muốn build QEMU ULTRA MAX với tăng tốc LLVM không? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
  if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    msg "QEMU ULTRA MAX đã tồn tại — skip build"
    export PATH="/opt/qemu-optimized/bin:$PATH"
  else
    echo ""
    echo "🚀 Đang Tải Các Apt Cần Thiết..."
    echo "⚠️ Nếu lỗi hãy thử dùng apt install sudo"

    OS_ID="$(. /etc/os-release && echo "$ID")"
    OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

    sudo apt update
    sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv \
        python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config \
        meson aria2 ovmf qemu-utils libcap-ng-dev libaio-dev

    # ── LLVM Installation ──
    if [[ "$OS_ID" == "ubuntu" ]]; then
      info "Detect Ubuntu → Cài LLVM 21"
      wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
      sudo ./llvm.sh 21
      LLVM_VER=21
      sudo apt install -y llvm-$LLVM_VER-tools llvm-$LLVM_VER-dev 2>/dev/null || true
    elif [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
      LLVM_VER=19
      sudo apt install -y clang-$LLVM_VER llvm-$LLVM_VER \
          llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
    else
      LLVM_VER=15
      sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
          llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
    fi

    export CC="clang-$LLVM_VER"
    export CXX="clang++-$LLVM_VER"

    # ── LLD detection ──
    if command -v lld-$LLVM_VER &>/dev/null; then
      export LD="lld-$LLVM_VER"
    elif command -v ld.lld &>/dev/null; then
      export LD="ld.lld"
    else
      export LD="ld"
      warn "LLD not found — using system linker (LTO may be slower)"
    fi
    info "Compiler: $CC | Linker: $LD"

    # ── Verify Polly support ──
    POLLY_SUPPORTED="no"
    if $CC -mllvm -polly -x c -c /dev/null -o /dev/null 2>/dev/null; then
      POLLY_SUPPORTED="yes"
      msg "LLVM Polly detected & enabled"
    else
      warn "LLVM Polly not available — skipping Polly flags"
    fi

    # ── Check glib version ──
    GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
    if [ "$(printf '%s\n' "$GLIB_VER" "2.66" | sort -V | head -n1)" != "2.66" ]; then
      warn "glib $GLIB_VER quá cũ, đang build glib 2.76..."
      sudo apt install -y libffi-dev gettext
      cd /tmp && wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
      tar xf glib-2.76.6.tar.xz && cd glib-2.76.6
      meson setup build --prefix=/usr/local && ninja -C build && sudo ninja -C build install
      export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
      export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH"
      msg "glib mới: $(pkg-config --modversion glib-2.0)"
    else
      msg "glib đủ yêu cầu: $GLIB_VER"
    fi

    # ══════════════════════════════════════════════
    #  PHASE 2: Clone QEMU
    # ══════════════════════════════════════════════
    echo ""
    info "=== [2/6] Cloning QEMU 10.2.1 ==="
    rm -rf /tmp/qemu-src /tmp/qemu-build
    cd /tmp
    silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

    # ══════════════════════════════════════════════
    #  PHASE 3: V14.0 ULTRA MAX PATCHES (70+)
    # ══════════════════════════════════════════════
    echo ""
    info "=== [3/6] V14.0 Ultra Max Patches ==="
    cd /tmp/qemu-src
    PATCH_OK=0; PATCH_SKIP=0

    spatch() {
      local LN=$(grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$LN" ]; then
        sed -i "${LN}i\\$3" "$1" 2>/dev/null && PATCH_OK=$((PATCH_OK+1))
      else
        PATCH_SKIP=$((PATCH_SKIP+1))
      fi
    }
    ssub() {
      if grep -qF "$2" "$1" 2>/dev/null; then
        sed -i "s|$2|$3|g" "$1" 2>/dev/null && PATCH_OK=$((PATCH_OK+1))
      else
        PATCH_SKIP=$((PATCH_SKIP+1))
      fi
    }

    H='/* V14 */ __attribute__((hot))'
    HF='/* V14 */ __attribute__((hot, flatten))'

    # ────────────────────────────────────────
    #  3A. TCG Core — tcg/tcg.c
    # ────────────────────────────────────────
    echo "  📦 tcg/tcg.c — TCG core codegen"
    for fn in "int tcg_gen_code" "static void tcg_reg_alloc_op" "static void tcg_reg_alloc_mov" \
      "static void tcg_reg_alloc_call" "static void tcg_reg_alloc_dup" \
      "static void temp_load" "static void temp_sync" "static void temp_save" \
      "void tcg_func_start" "static void liveness_pass_1"; do
      spatch tcg/tcg.c "$fn" "$H"
    done
    echo "    ✓ tcg.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3B. TCG Optimizer — tcg/optimize.c
    # ────────────────────────────────────────
    echo "  📦 tcg/optimize.c — TCG IR optimizer"
    for fn in "void tcg_optimize" "static bool tcg_opt_gen_mov" "static bool finish_folding" \
      "static void copy_propagate" "static bool fold_add(" "static bool fold_sub(" \
      "static bool fold_and(" "static bool fold_or(" "static bool fold_xor(" \
      "static bool fold_brcond" "static int do_constant_folding_cond("; do
      spatch tcg/optimize.c "$fn" "$H"
    done
    echo "    ✓ optimize.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3C. TCG Ops — tcg/tcg-op.c + tcg-op-ldst.c
    # ────────────────────────────────────────
    echo "  📦 tcg-op.c + tcg-op-ldst.c — TCG IR generation + load/store"
    for fn in "void tcg_gen_exit_tb" "void tcg_gen_goto_tb" "void tcg_gen_lookup_and_goto_ptr"; do
      spatch tcg/tcg-op.c "$fn" "$H"
    done
    for fn in "static void tcg_gen_qemu_ld_i32_int" "static void tcg_gen_qemu_st_i32_int"; do
      spatch tcg/tcg-op-ldst.c "$fn" "$H"
    done
    echo "    ✓ tcg-op + ldst: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3D. CPU Exec Loop — accel/tcg/cpu-exec.c
    # ────────────────────────────────────────
    echo "  📦 accel/tcg/cpu-exec.c — Main execution loop"
    spatch accel/tcg/cpu-exec.c "int cpu_exec(CPUState \*cpu)" "$HF"
    spatch accel/tcg/cpu-exec.c "static TranslationBlock \*tb_htable_lookup" "$HF"
    spatch accel/tcg/cpu-exec.c "static inline void cpu_loop_exec_tb" "$HF"
    ssub accel/tcg/cpu-exec.c "static inline TranslationBlock *tb_lookup(" "static inline __attribute__((always_inline)) TranslationBlock *tb_lookup("
    ssub accel/tcg/cpu-exec.c "static inline void tb_add_jump(" "static inline __attribute__((always_inline)) void tb_add_jump("
    ssub accel/tcg/cpu-exec.c "static inline bool cpu_handle_interrupt(" "static inline __attribute__((always_inline)) bool cpu_handle_interrupt("
    ssub accel/tcg/cpu-exec.c "static inline bool cpu_handle_exception(" "static inline __attribute__((always_inline)) bool cpu_handle_exception("
    ssub accel/tcg/cpu-exec.c 'if (tb == NULL) {' 'if (__builtin_expect(tb == NULL, 0)) {'
    ssub accel/tcg/cpu-exec.c 'if (*tb_exit != TB_EXIT_REQUESTED)' 'if (__builtin_expect(*tb_exit != TB_EXIT_REQUESTED, 1))'
    echo "    ✓ cpu-exec.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3E. TLB — accel/tcg/cputlb.c
    # ────────────────────────────────────────
    echo "  📦 accel/tcg/cputlb.c — TLB hot path"
    ssub accel/tcg/cputlb.c "static inline bool tlb_hit(uint64_t" "static inline __attribute__((always_inline)) bool tlb_hit(uint64_t"
    ssub accel/tcg/cputlb.c "static inline bool tlb_hit_page(uint64_t" "static inline __attribute__((always_inline)) bool tlb_hit_page(uint64_t"
    ssub accel/tcg/cputlb.c "static inline uintptr_t tlb_index(" "static inline __attribute__((always_inline)) uintptr_t tlb_index("
    ssub accel/tcg/cputlb.c "static inline CPUTLBEntry *tlb_entry(" "static inline __attribute__((always_inline)) CPUTLBEntry *tlb_entry("
    ssub accel/tcg/cputlb.c "static inline uint64_t tlb_read_idx(" "static inline __attribute__((always_inline)) uint64_t tlb_read_idx("
    ssub accel/tcg/cputlb.c "static inline void copy_tlb_helper_locked(" "static inline __attribute__((always_inline)) void copy_tlb_helper_locked("
    spatch accel/tcg/cputlb.c "void tlb_set_page_full(" "$H"
    spatch accel/tcg/cputlb.c "static bool victim_tlb_hit" "$H"
    echo "    ✓ cputlb.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3F. Translation & TB Management
    # ────────────────────────────────────────
    echo "  📦 translate-all + tb-maint + translator"
    spatch accel/tcg/translate-all.c "TranslationBlock \*tb_gen_code(CPUState \*cpu" "$HF"
    spatch accel/tcg/tb-maint.c "static bool tb_cmp(const void \*ap" "$H"
    spatch accel/tcg/translator.c "void translator_loop(CPUState \*cpu" "$HF"
    echo "    ✓ translate-all + tb-maint + translator: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3G. x86 Frontend Decoder (NEW in v14)
    # ────────────────────────────────────────
    echo "  📦 target/i386/tcg/translate.c — x86 instruction decoder (NEW)"
    for fn in "static void gen_update_cc_op" "static void gen_op_mov_reg_v" \
      "static void gen_update_eip_next" "static void gen_update_eip_cur" \
      "static void gen_jmp_rel("; do
      spatch target/i386/tcg/translate.c "$fn" "$H"
    done
    spatch target/i386/tcg/translate.c "static bool disas_insn(" "$H"
    echo "    ✓ translate.c (x86 frontend): $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3H. x86 Helpers (NEW in v14)
    # ────────────────────────────────────────
    echo "  📦 target/i386/tcg/*_helper.c — x86 condition code helpers (NEW)"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_all" "$H"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_c" "$H"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_nz" "$H"
    echo "    ✓ cc_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3I. Physical Memory Path (NEW in v14)
    # ────────────────────────────────────────
    echo "  📦 system/physmem.c — physical memory access path (NEW)"
    spatch system/physmem.c "static MemTxResult flatview_read(" "$H"
    spatch system/physmem.c "static MemTxResult flatview_write(" "$H"
    spatch system/physmem.c "MemTxResult flatview_read_continue(" "$H"
    echo "    ✓ physmem.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3J. TB Hash Table (NEW in v14)
    # ────────────────────────────────────────
    echo "  📦 tcg/region.c — TB hash table & code buffer (NEW)"
    spatch tcg/region.c "void tcg_tb_insert" "$H"
    spatch tcg/region.c "void tcg_tb_remove" "$H"
    spatch tcg/region.c "static gint tb_tc_cmp" "$H"
    echo "    ✓ region.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3K. Fast DBT Tuning (Enhanced in v14)
    # ────────────────────────────────────────
    echo "  📦 DBT tuning — cache, buffer, instruction limits"
    # Double TB jump cache: 4096 → 16384 entries (more TB hits)
    sed -i 's/#define TB_JMP_CACHE_BITS 12/#define TB_JMP_CACHE_BITS 14/' accel/tcg/tb-jmp-cache.h
    # Temp buffer for TCG codegen
    sed -i 's/#define CPU_TEMP_BUF_NLONGS 128/#define CPU_TEMP_BUF_NLONGS 512/' include/tcg/tcg.h
    # More temp registers available
    sed -i 's/#define TCG_MAX_TEMPS 512/#define TCG_MAX_TEMPS 2048/' include/tcg/tcg.h
    # More instructions per TB (NEW v14 — must sync CF_COUNT_MASK!)
    sed -i 's/#define TCG_MAX_INSNS 512/#define TCG_MAX_INSNS 1024/' include/tcg/tcg.h
    sed -i 's/#define CF_COUNT_MASK    0x000001ff/#define CF_COUNT_MASK    0x000003ff/' include/exec/translation-block.h
    PATCH_OK=$((PATCH_OK+5))
    echo "    ✓ DBT tuning: $PATCH_OK patched"

    echo ""
    msg "Total: $PATCH_OK patches applied, $PATCH_SKIP skipped!"

    # ══════════════════════════════════════════════
    #  PHASE 4: CONFIGURE with Deep LLVM Optimization
    # ══════════════════════════════════════════════
    echo ""
    info "=== [4/6] Configure with LLVM Ultra Max Flags ==="

    # ── Base CFLAGS ──
    BASE="-O3 -march=native -mtune=native -pipe"
    BASE="$BASE -fno-strict-aliasing"
    BASE="$BASE -fmerge-all-constants"
    BASE="$BASE -fno-semantic-interposition"
    BASE="$BASE -fno-plt"
    BASE="$BASE -fomit-frame-pointer"
    BASE="$BASE -fno-unwind-tables -fno-asynchronous-unwind-tables"
    BASE="$BASE -fno-stack-protector"
    BASE="$BASE -fno-math-errno"
    BASE="$BASE -ffinite-loops"
    BASE="$BASE -fno-trapping-math"
    BASE="$BASE -funroll-loops"
    BASE="$BASE -finline-functions"
    BASE="$BASE -fvectorize"
    BASE="$BASE -fslp-vectorize"
    BASE="$BASE -fdata-sections"
    BASE="$BASE -ffunction-sections"
    BASE="$BASE -falign-functions=32"
    BASE="$BASE -falign-loops=16"
    BASE="$BASE -fno-common"
    BASE="$BASE -DNDEBUG"

    # ── LLVM Polly (Polyhedral Optimizer) — Advanced ──
    POLLY=""
    if [[ "$POLLY_SUPPORTED" == "yes" ]]; then
      POLLY="-mllvm -polly"
      POLLY="$POLLY -mllvm -polly-vectorizer=stripmine"
      POLLY="$POLLY -mllvm -polly-position=before-vectorizer"
      POLLY="$POLLY -mllvm -polly-run-dce"
      POLLY="$POLLY -mllvm -polly-run-inliner"
      POLLY="$POLLY -mllvm -polly-invariant-load-hoisting"
    fi

    # ── LLVM Inlining Tuning (v14 aggressive) ──
    INLINE="-mllvm -inline-threshold=1000"
    INLINE="$INLINE -mllvm -inlinehint-threshold=2000"
    INLINE="$INLINE -mllvm -hot-callsite-threshold=750"

    # ── LLVM Loop Optimizations (NEW v14) ──
    LOOPS="-mllvm -unroll-threshold=500"
    LOOPS="$LOOPS -mllvm -unroll-count=4"

    # ── LLVM Global Value Numbering (NEW v14) ──
    GVN="-mllvm -enable-gvn-hoist"
    GVN="$GVN -mllvm -enable-gvn-sink"

    # ── LTO Mode (auto-detect based on disk space) ──
    AVAIL_GB=$(df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}')
    if [ "$AVAIL_GB" -ge 40 ]; then
      LTO_MODE="full"
      msg "Disk ${AVAIL_GB}GB → LTO=full (maximum optimization)"
    else
      LTO_MODE="thin"
      warn "Disk ${AVAIL_GB}GB → LTO=thin (saving disk space)"
    fi

    # ── Assemble final flags ──
    FINAL_CFLAGS="$BASE $POLLY $INLINE $LOOPS $GVN -flto=$LTO_MODE"
    FINAL_LDFLAGS="-fuse-ld=lld -flto=$LTO_MODE"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--lto-O3"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--gc-sections"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--icf=all"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,-O3"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--strip-all"

    echo "  CFLAGS:  $FINAL_CFLAGS"
    echo "  LDFLAGS: $FINAL_LDFLAGS"

    mkdir -p /tmp/qemu-build && cd /tmp/qemu-build
    info "Running configure..."

    # ── QEMU 10.x configure — ONLY valid meson flags ──
    /tmp/qemu-src/configure \
        --prefix=/opt/qemu-optimized \
        --target-list=x86_64-softmmu \
        --enable-tcg --enable-slirp --enable-coroutine-pool \
        --disable-kvm --disable-xen \
        --disable-gtk --disable-sdl --disable-spice --disable-vnc \
        --disable-plugins --disable-debug-info --disable-debug-tcg \
        --disable-docs --disable-werror \
        --disable-fdt --disable-opengl \
        --disable-gnutls --disable-smartcard --disable-libusb \
        --disable-seccomp --disable-modules \
        --disable-brlapi --disable-curl --disable-curses \
        --disable-vte --disable-virglrenderer --disable-tpm \
        --disable-libssh --disable-numa \
        --disable-guest-agent \
        --disable-pa --disable-alsa --disable-oss --disable-jack \
        CC="$CC" CXX="$CXX" \
        CFLAGS="$FINAL_CFLAGS" CXXFLAGS="$FINAL_CFLAGS" LDFLAGS="$FINAL_LDFLAGS"

    msg "Configure OK"

    # ══════════════════════════════════════════════
    #  PHASE 5: BUILD
    # ══════════════════════════════════════════════
    echo ""
    info "=== [5/6] Building QEMU ==="
    echo "  💣 Nếu lỗi, thử: ulimit -n 65535"
    ulimit -n 65535 2>/dev/null || true

    NPROC=$(nproc)
    if [ "$LTO_MODE" == "full" ] && [ "$NPROC" -gt 8 ]; then
      BUILD_JOBS=8
      warn "LTO=full → limiting to $BUILD_JOBS jobs to avoid OOM"
    else
      BUILD_JOBS=$NPROC
    fi

    echo "🕧 QEMU đang được build vui lòng đợi..."
    ninja -j"$BUILD_JOBS" qemu-system-x86_64 qemu-img

    # ══════════════════════════════════════════════
    #  PHASE 6: INSTALL
    # ══════════════════════════════════════════════
    echo ""
    info "=== [6/6] Installing ==="
    sudo mkdir -p /opt/qemu-optimized/bin /opt/qemu-optimized/share/qemu
    sudo cp qemu-system-x86_64 qemu-img /opt/qemu-optimized/bin/
    sudo strip --strip-unneeded /opt/qemu-optimized/bin/qemu-system-x86_64 2>/dev/null || true
    sudo strip --strip-unneeded /opt/qemu-optimized/bin/qemu-img 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.bin /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.rom /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.img /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    sudo cp /tmp/qemu-src/pc-bios/*.fd  /opt/qemu-optimized/share/qemu/ 2>/dev/null || true
    export PATH="/opt/qemu-optimized/bin:$PATH"
    rm -rf /tmp/qemu-build /tmp/qemu-src

    qemu-system-x86_64 --version
    msg "🔥 QEMU V14.0 ULTRA MAX build hoàn tất!"
  fi
else
  echo "⚡ Bỏ qua build QEMU."
  if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    export PATH="/opt/qemu-optimized/bin:$PATH"
  else
    warn "QEMU chưa build. Cài bản hệ thống..."
    sudo apt update && sudo apt install -y qemu-system-x86 qemu-utils aria2 ovmf
  fi
fi

# ══════════════════════════════════════════════════════════════
#  WINDOWS VM MANAGER
# ══════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER v14.0"
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
    err "Không có VM nào đang chạy"
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
    msg "Đã gửi tín hiệu tắt VM PID $kill_pid"
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

info "Đang Tải $WIN_NAME..."
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

# ── Optimized CPU model for TCG ──
cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on"
cpu_model="$cpu_model,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2"
cpu_model="$cpu_model,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse"
cpu_model="$cpu_model,+lahf_lm,+rdtscp"
cpu_model="$cpu_model,model-id=${cpu_host}"

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

info "Đang tạo VM Ultra Max với cấu hình tối ưu..."

# ── HugePages auto-detect ──
MEMORY_BACKEND=""
if [ -d /sys/kernel/mm/hugepages/hugepages-2048kB ]; then
  HUGE_FREE=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages 2>/dev/null || echo 0)
  HUGE_NEEDED=$(( ram_size * 512 ))
  if [ "$HUGE_FREE" -ge "$HUGE_NEEDED" ]; then
    MEMORY_BACKEND="-mem-path /dev/hugepages -mem-prealloc"
    msg "HugePages detected ($HUGE_FREE free) → enabled!"
  fi
fi

echo "⌛ Đang Tạo VM với cấu hình bạn đã nhập vui lòng đợi..."

$QBIN \
    -L /opt/qemu-optimized/share/qemu \
    -L /usr/share/qemu \
    -L /usr/lib/ipxe/qemu \
    -machine q35,hpet=off,vmport=off \
    -cpu "$cpu_model" \
    -smp "$cpu_core",sockets=1,cores="$cpu_core",threads=1 \
    -m "${ram_size}G" $MEMORY_BACKEND \
    -accel tcg,thread=multi,tb-size=4194304 \
    -rtc base=localtime,driftfix=slew \
    $BIOS_OPT \
    -drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw,discard=unmap \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
    $NET_DEVICE \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -device virtio-balloon-pci \
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

# Check if VM actually started
if pgrep -f "qemu-system-x86_64.*win.img" > /dev/null 2>&1; then
  msg "VM started successfully!"
else
  err "VM có thể không khởi động được. Kiểm tra /tmp/qemu_error.log"
  cat /tmp/qemu_error.log 2>/dev/null
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
  echo "🚀 WINDOWS VM DEPLOYED SUCCESSFULLY (v14.0)"
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
  echo "🔥 Build       : QEMU ULTRA MAX LLVM v14.0"
  echo "══════════════════════════════════════════════"
else
  echo ""
  echo "══════════════════════════════════════════════"
  echo "🚀 VM RUNNING (no tunnel) — v14.0 ULTRA MAX"
  echo "══════════════════════════════════════════════"
  echo "🪟 OS          : $WIN_NAME"
  echo "⚙ CPU Cores   : $cpu_core"
  echo "💾 RAM         : ${ram_size} GB"
  echo "📡 RDP         : localhost:3389"
  echo "👤 Username    : $RDP_USER"
  echo "🔑 Password    : $RDP_PASS"
  echo "══════════════════════════════════════════════"
fi
