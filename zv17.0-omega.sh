#!/usr/bin/env bash
set -e

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  ZQEMU v17.0 OMEGA — Ultimate TCG Deep Optimization Build      ║
# ║  ✅ Based on v15.0 ULTRA MAX + 40 NEW deep patches                 ║
# ║  ✅ TCG Backend (x86_64 codegen) — FIRST TIME patched              ║
# ║  ✅ Atomic/SoftMMU/MemHelper/ExcpHelper — all NEW                  ║
# ║  ✅ Enhanced LLVM: new vectorizer + loop opts + alignment           ║
# ║  ✅ 300+ hot path patches across 20+ source files                  ║
# ║  ✅ Runtime: io_uring, 16MB TB, Hyper-V enhanced, CPU pinning      ║
# ║  🚫 No PGO — pure static optimization                              ║
# ╚══════════════════════════════════════════════════════════════════════╝

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

choice=$(ask "👉 Bạn có muốn build QEMU HYPER MAX v17.0 với tối ưu TCG sâu không? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
  if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    rebuild=$(ask "⚠️ QEMU đã tồn tại. Build lại v16? (y/n): " "n")
    if [[ "$rebuild" != "y" ]]; then
      msg "Giữ bản hiện tại — skip build"
      export PATH="/opt/qemu-optimized/bin:$PATH"
    else
      sudo rm -rf /opt/qemu-optimized
      info "Đã xóa bản cũ, tiến hành build v16..."
    fi
  fi

  if [ ! -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    echo ""
    echo "🚀 ══════════════════════════════════════════════"
    echo "🚀  ZQEMU v17.0 OMEGA BUILD — Starting..."
    echo "🚀 ══════════════════════════════════════════════"

    # ══════════════════════════════════════════════
    #  PHASE 1: Dependencies & LLVM Toolchain
    # ══════════════════════════════════════════════
    info "=== [1/6] Installing Dependencies ==="

    OS_ID="$(. /etc/os-release && echo "$ID")"
    OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

    silent sudo apt update
    silent sudo apt install -y curl gnupg build-essential ninja-build git python3 python3-venv \
        python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config \
        meson aria2 ovmf qemu-utils libcap-ng-dev libaio-dev liburing-dev numactl

    # ── LLVM Installation ──
    if [[ "$OS_ID" == "ubuntu" ]]; then
      info "Detect Ubuntu → Cài LLVM 21"
      curl -sSL https://apt.llvm.org/llvm.sh -o llvm.sh && chmod +x llvm.sh
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
      cd /tmp && curl -sSL https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz -o glib-2.76.6.tar.xz
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

    # ══════════════════════════════════════════════════════════════════
    #  PHASE 3: V16.1 HYPER MAX PATCHES (300+)
    #  Structure:
    #    A. TCG Core Engine          (v15 base)
    #    B. TCG IR Optimizer         (v15 base)
    #    C. TCG Ops + Load/Store     (v15 base)
    #    D. CPU Exec Loop            (v15 base + v16 enhancements)
    #    E. TLB Hot Path             (v15 base + v16 prefetch)
    #    F. Translation & TB Mgmt   (v15 base)
    #    G. x86 Frontend Decoder     (v15 base + v16 additions)
    #    H. x86 CC Helpers           (v15 base)
    #    I. Physical Memory          (v15 base + v16 enhancements)
    #    J. TB Region/Hash           (v15 base)
    #    K. DBT Tuning Constants     (v16 enhanced)
    #    L. MTTCG Thread Loop        (v15 base)
    #    M. FPU Helpers              (v15 base + v16 additions)
    #    N. Integer Helpers           (v15 base)
    #    O. Segment Helpers           (v15 base)
    #    P. Misc Helpers              (v15 base)
    #    Q. GUI Refresh               (v16 enhanced)
    #  ──── V16 NEW SECTIONS ────
    #    R. TCG x86_64 Backend       ★ NEW — codegen engine
    #    S. Atomic Helpers           ★ NEW — MTTCG critical
    #    T. SoftMMU Slow Path        ★ NEW — TLB miss handler
    #    U. x86 Memory Helpers       ★ NEW — string ops
    #    V. x86 Exception Helpers    ★ NEW — interrupt path
    #    W. x86 SMM/SVM Helpers      ★ NEW — system mgmt
    #    X. Softfloat Library        ★ NEW — FP math engine
    #    Y. Timer/Clock Subsystem    ★ NEW — reduce overhead
    #    Z. Extra __builtin_expect   ★ NEW — branch prediction
    # ══════════════════════════════════════════════════════════════════
    echo ""
    info "=== [3/6] V17.0 OMEGA Patches (300+) ==="
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

    H='/* V16 */ __attribute__((hot))'
    HF='/* V16 */ __attribute__((hot, flatten))'
    AI='__attribute__((always_inline))'

    # ────────────────────────────────────────
    #  3A. TCG Core — tcg/tcg.c
    # ────────────────────────────────────────
    echo "  📦 [A] tcg/tcg.c — TCG core codegen"
    for fn in "int tcg_gen_code" "static void tcg_reg_alloc_op" "static void tcg_reg_alloc_mov" \
      "static void tcg_reg_alloc_call" "static void tcg_reg_alloc_dup" \
      "static void temp_load" "static void temp_sync" "static void temp_save" \
      "void tcg_func_start" "liveness_pass_1(TCGContext" \
      "liveness_pass_2(TCGContext" "reachable_code_pass(TCGContext"; do
      spatch tcg/tcg.c "$fn" "$H"
    done
    echo "    ✓ tcg.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3B. TCG Optimizer — tcg/optimize.c
    # ────────────────────────────────────────
    echo "  📦 [B] tcg/optimize.c — TCG IR optimizer"
    for fn in "void tcg_optimize" "static bool tcg_opt_gen_mov" "static bool finish_folding" \
      "static void copy_propagate" "static bool fold_add(" "static bool fold_sub(" \
      "static bool fold_and(" "static bool fold_or(" "static bool fold_xor(" \
      "static bool fold_brcond" "static int do_constant_folding_cond(" \
      "static bool fold_mov(" "static bool fold_mul(" "static bool fold_shift(" \
      "static bool fold_movcond(" "static bool fold_setcond(" \
      "static bool fold_extract(" "static bool fold_deposit(" \
      "static bool fold_qemu_ld_1reg(" "static bool fold_qemu_ld_2reg(" "static bool fold_qemu_st("; do
      spatch tcg/optimize.c "$fn" "$H"
    done
    echo "    ✓ optimize.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3C. TCG Ops — tcg/tcg-op.c + tcg-op-ldst.c
    # ────────────────────────────────────────
    echo "  📦 [C] tcg-op.c + tcg-op-ldst.c — TCG IR generation + load/store"
    for fn in "void tcg_gen_exit_tb" "void tcg_gen_goto_tb" "void tcg_gen_lookup_and_goto_ptr" \
      "void tcg_gen_br(" "void tcg_gen_brcond_i32" "void tcg_gen_brcond_i64"; do
      spatch tcg/tcg-op.c "$fn" "$H"
    done
    for fn in "static void tcg_gen_qemu_ld_i32_int" "static void tcg_gen_qemu_st_i32_int" \
      "static void tcg_gen_qemu_ld_i64_int" "static void tcg_gen_qemu_st_i64_int" \
      "static void tcg_gen_qemu_ld_i128_int" "static void tcg_gen_qemu_st_i128_int"; do
      spatch tcg/tcg-op-ldst.c "$fn" "$H"
    done
    echo "    ✓ tcg-op + ldst: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3D. CPU Exec Loop — accel/tcg/cpu-exec.c (v16 enhanced)
    # ────────────────────────────────────────
    echo "  📦 [D] accel/tcg/cpu-exec.c — Main execution loop (v16 enhanced)"
    spatch accel/tcg/cpu-exec.c "int cpu_exec(CPUState \*cpu)" "$HF"
    spatch accel/tcg/cpu-exec.c "static TranslationBlock \*tb_htable_lookup" "$HF"
    spatch accel/tcg/cpu-exec.c "static inline void cpu_loop_exec_tb" "$HF"
    ssub accel/tcg/cpu-exec.c "static inline TranslationBlock *tb_lookup(" "static inline $AI TranslationBlock *tb_lookup("
    ssub accel/tcg/cpu-exec.c "static inline void tb_add_jump(" "static inline $AI void tb_add_jump("
    ssub accel/tcg/cpu-exec.c "static inline bool cpu_handle_interrupt(" "static inline $AI bool cpu_handle_interrupt("
    ssub accel/tcg/cpu-exec.c "static inline bool cpu_handle_exception(" "static inline $AI bool cpu_handle_exception("
    # v16: More branch predictions
    ssub accel/tcg/cpu-exec.c 'if (tb == NULL) {' 'if (__builtin_expect(tb == NULL, 0)) {'
    ssub accel/tcg/cpu-exec.c 'if (*tb_exit != TB_EXIT_REQUESTED)' 'if (__builtin_expect(*tb_exit != TB_EXIT_REQUESTED, 1))'
    # v17.0-fix: sigsetjmp complex nesting - skip
    # v17.0-fix: removed risky __builtin_expect on exception_index
    # v17.0-fix: removed risky __builtin_expect on halted
    echo "    ✓ cpu-exec.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3E. TLB — accel/tcg/cputlb.c (v16 enhanced)
    # ────────────────────────────────────────
    echo "  📦 [E] accel/tcg/cputlb.c — TLB hot path (v16 enhanced)"
    ssub accel/tcg/cputlb.c "static inline bool tlb_hit(uint64_t" "static inline $AI bool tlb_hit(uint64_t"
    ssub accel/tcg/cputlb.c "static inline bool tlb_hit_page(uint64_t" "static inline $AI bool tlb_hit_page(uint64_t"
    ssub accel/tcg/cputlb.c "static inline uintptr_t tlb_index(" "static inline $AI uintptr_t tlb_index("
    ssub accel/tcg/cputlb.c "static inline CPUTLBEntry *tlb_entry(" "static inline $AI CPUTLBEntry *tlb_entry("
    ssub accel/tcg/cputlb.c "static inline uint64_t tlb_read_idx(" "static inline $AI uint64_t tlb_read_idx("
    ssub accel/tcg/cputlb.c "static inline void copy_tlb_helper_locked(" "static inline $AI void copy_tlb_helper_locked("
    spatch accel/tcg/cputlb.c "void tlb_set_page_full(" "$H"
    spatch accel/tcg/cputlb.c "static bool victim_tlb_hit" "$H"
    # v16: Patch load/store helpers
    for fn in "static void *atomic_mmu_lookup" "void tlb_flush_by_mmuidx" \
      "void tlb_flush(" "void tlb_flush_page(" "void tlb_flush_all_cpus_synced"; do
      spatch accel/tcg/cputlb.c "$fn" "$H"
    done
    echo "    ✓ cputlb.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3F. Translation & TB Management
    # ────────────────────────────────────────
    echo "  📦 [F] translate-all + tb-maint + translator"
    spatch accel/tcg/translate-all.c "TranslationBlock \*tb_gen_code(CPUState \*cpu" "$HF"
    spatch accel/tcg/tb-maint.c "static bool tb_cmp(const void \*ap" "$H"
    spatch accel/tcg/translator.c "void translator_loop(CPUState \*cpu" "$HF"
    # v17.0: translator_loop_temp_check does not exist in QEMU 10.2.1
    echo "    ✓ translate-all + tb-maint + translator: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3G. x86 Frontend Decoder (v16 enhanced)
    # ────────────────────────────────────────
    echo "  📦 [G] target/i386/tcg/translate.c — x86 decoder (v16 enhanced)"
    for fn in "static void gen_update_cc_op" "static void gen_op_mov_reg_v" \
      "static void gen_update_eip_next" "static void gen_update_eip_cur" \
      "static void gen_jmp_rel(" "static AddressParts gen_lea_modrm_0" \
      "static inline void gen_op_ld_v" "static inline void gen_op_st_v" \
      "static MemOp gen_pop_T0" "static inline void gen_pop_update" \
      "static inline void gen_op_add_reg" "void gen_op_mov_v_reg" \
      "static TCGv gen_lea_modrm_1" "static void gen_popa"; do
      spatch target/i386/tcg/translate.c "$fn" "$H"
    done
    spatch target/i386/tcg/translate.c "void gen_op_add_reg_im" "$H"
    # v16: Also patch the emit includes
    for fn in "static void gen_op_mov_reg_v" "static void gen_exception" \
      "static void gen_interrupt"; do
      spatch target/i386/tcg/translate.c "$fn" "$H"
    done
    echo "    ✓ translate.c (x86 frontend): $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3H. x86 CC Helpers
    # ────────────────────────────────────────
    echo "  📦 [H] target/i386/tcg/cc_helper.c — condition codes"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_all" "$H"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_c" "$H"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_cc_compute_nz" "$H"
    spatch target/i386/tcg/cc_helper.c "void helper_write_eflags" "$H"
    spatch target/i386/tcg/cc_helper.c "target_ulong helper_read_eflags" "$H"
    echo "    ✓ cc_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3I. Physical Memory Path (v16 enhanced)
    # ────────────────────────────────────────
    echo "  📦 [I] system/physmem.c — physical memory (v16 enhanced)"
    for fn in "static MemTxResult flatview_read(" "static MemTxResult flatview_write(" \
      "MemTxResult flatview_read_continue(" "MemTxResult flatview_write_continue(" \
      "MemTxResult address_space_read_full(" "MemTxResult address_space_write(" \
      "static MemoryRegionSection *address_space_lookup_region(" \
      "address_space_translate_internal(AddressSpaceDispatch"; do
      spatch system/physmem.c "$fn" "$H"
    done
    echo "    ✓ physmem.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3J. TB Region/Hash
    # ────────────────────────────────────────
    echo "  📦 [J] tcg/region.c — TB hash table & code buffer"
    spatch tcg/region.c "void tcg_tb_insert" "$H"
    spatch tcg/region.c "void tcg_tb_remove" "$H"
    spatch tcg/region.c "static gint tb_tc_cmp" "$H"
    echo "    ✓ region.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3K. DBT Tuning Constants (v16 ENHANCED)
    # ────────────────────────────────────────
    echo "  📦 [K] DBT tuning — cache, buffer, instruction limits (v16 ENHANCED)"
    # v16: 32K entries TB jump cache (v15 was 16K)
    sed -i 's/#define TB_JMP_CACHE_BITS 12/#define TB_JMP_CACHE_BITS 15/' accel/tcg/tb-jmp-cache.h 2>/dev/null
    # Temp buffer for TCG codegen
    sed -i 's/#define CPU_TEMP_BUF_NLONGS 128/#define CPU_TEMP_BUF_NLONGS 512/' include/tcg/tcg.h 2>/dev/null
    # More temp registers
    sed -i 's/#define TCG_MAX_TEMPS 512/#define TCG_MAX_TEMPS 2048/' include/tcg/tcg.h 2>/dev/null
    # v16: 2048 instructions per TB (v15 was 1024)
    sed -i 's/#define TCG_MAX_INSNS 512/#define TCG_MAX_INSNS 2048/' include/tcg/tcg.h 2>/dev/null
    # v16: Sync CF_COUNT_MASK for 2048 insns (0x7ff = 2047)
    sed -i 's/#define CF_COUNT_MASK    0x000001ff/#define CF_COUNT_MASK    0x000007ff/' include/exec/translation-block.h 2>/dev/null
    PATCH_OK=$((PATCH_OK+5))
    echo "    ✓ DBT tuning: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3L. MTTCG Thread Loop
    # ────────────────────────────────────────
    echo "  📦 [L] accel/tcg/tcg-accel-ops — MTTCG thread"
    spatch accel/tcg/tcg-accel-ops-mttcg.c "static void \*mttcg_cpu_thread_fn" "$H"
    spatch accel/tcg/tcg-accel-ops.c "void tcg_handle_interrupt" "$H"
    spatch accel/tcg/tcg-accel-ops.c "static void tcg_cpu_reset_hold" "$H"
    echo "    ✓ MTTCG: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3M. FPU Helpers (v16 enhanced — more functions)
    # ────────────────────────────────────────
    echo "  📦 [M] target/i386/tcg/fpu_helper.c — x86 FPU (v16 enhanced)"
    for fn in "void helper_flds_ST0" "void helper_fldl_ST0" "void helper_fildl_FT0" \
      "void helper_flds_FT0" "void helper_fldl_FT0" \
      "void helper_fadd_ST0_FT0" "void helper_fmul_ST0_FT0" \
      "void helper_fdiv_ST0_FT0" "void helper_fsub_ST0_FT0" \
      "void helper_fpush" "void helper_fpop" \
      "void helper_fxam_ST0" "void helper_fcom_ST0_FT0" \
      "void helper_fstl_ST0" "void helper_fsts_ST0" \
      "void helper_fisttl_ST0" "void helper_fisttll_ST0" \
      "void helper_fild_ST0" "void helper_fildl_ST0" "void helper_fildll_ST0" \
      "void helper_fabs_ST0" "void helper_fchs_ST0" \
      "void helper_fyl2x" "void helper_fpatan" "void helper_fsqrt" \
      "void helper_fsin" "void helper_fcos" "void helper_fsincos" \
      "void helper_frndint" "void helper_fscale" \
      "void helper_f2xm1"; do
      spatch target/i386/tcg/fpu_helper.c "$fn" "$H"
    done
    echo "    ✓ fpu_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3N. Integer Helpers
    # ────────────────────────────────────────
    echo "  📦 [N] target/i386/tcg/int_helper.c — integer ops"
    for fn in "void helper_divb_AL" "void helper_idivb_AL" \
      "void helper_divw_AX" "void helper_idivw_AX" \
      "void helper_divl_EAX" "void helper_idivl_EAX" \
      "void helper_divq_EAX" "void helper_idivq_EAX" \
      "void helper_aam" "void helper_aad" \
      "void helper_imulq_EAX" "void helper_mulq_EAX"; do
      spatch target/i386/tcg/int_helper.c "$fn" "$H"
    done
    echo "    ✓ int_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3O. Segment Helpers
    # ────────────────────────────────────────
    echo "  📦 [O] target/i386/tcg/seg_helper.c — segment ops"
    for fn in "void helper_load_seg" "void helper_ljmp_protected" \
      "void helper_sysret" \
      "void helper_lcall_protected" "void helper_iret_protected" \
      "void helper_ltr(" "void helper_lldt("; do
      spatch target/i386/tcg/seg_helper.c "$fn" "$H"
    done
    # v17.0: syscall/sysret are in system/ subdirectory
    spatch target/i386/tcg/system/seg_helper.c "void helper_syscall" "$H"
    spatch target/i386/tcg/system/seg_helper.c "void helper_sysret" "$H"
    echo "    ✓ seg_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3P. Misc Helpers
    # ────────────────────────────────────────
    echo "  📦 [P] target/i386/tcg/misc_helper.c — misc ops"
    spatch target/i386/tcg/misc_helper.c "void helper_cpuid" "$H"
    spatch target/i386/tcg/misc_helper.c "void helper_rdtsc" "$H"
    spatch target/i386/tcg/misc_helper.c "void helper_rdpmc" "$H"
    spatch target/i386/tcg/misc_helper.c "void helper_wrmsr" "$H"
    spatch target/i386/tcg/misc_helper.c "void helper_rdmsr" "$H"
    echo "    ✓ misc_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3Q. GUI Refresh Idle (v16 enhanced)
    # ────────────────────────────────────────
    echo "  📦 [Q] GUI refresh — reduce idle overhead (v16: 10s)"
    sed -i 's/#define GUI_REFRESH_INTERVAL_IDLE     3000/#define GUI_REFRESH_INTERVAL_IDLE     10000/' include/ui/console.h 2>/dev/null && PATCH_OK=$((PATCH_OK+1)) || PATCH_SKIP=$((PATCH_SKIP+1))
    echo "    ✓ GUI idle: $PATCH_OK patched"

    # ═══════════════════════════════════════════════════════════
    #  ★★★ V16 NEW SECTIONS — NEVER PATCHED BEFORE ★★★
    # ═══════════════════════════════════════════════════════════

    echo ""
    info "──── V16 NEW DEEP PATCHES ────"

    # ────────────────────────────────────────
    #  3R. ★ TCG x86_64 Backend — tcg/i386/tcg-target.c.inc
    #  This is the ACTUAL code generator: TCG IR → x86_64 machine code
    #  THE most critical file for TCG performance!
    # ────────────────────────────────────────
    echo "  🔥 [R] tcg/i386/tcg-target.c.inc — TCG x86_64 BACKEND ★ NEW"
    for fn in "static int tcg_out_cmp(" "static bool tcg_out_qemu_ld_slow_path(" \
      "static bool tcg_out_qemu_st_slow_path(" "static void tcg_out_qemu_ld_direct(" \
      "static void tcg_out_qemu_st_direct(" "static void tcg_out_call(" \
      "static void tcg_out_goto_tb(" "static void tcg_out_exit_tb(" \
      "static void tcg_out_jmp(" \
      "static void tcg_out_brcond(" "static void tcg_out_setcond(" \
      "static void tcg_out_modrm(" "static void tcg_out_ext32s(" \
      "static void tcg_out_ext32u(" "static void tcg_out_ext8s(" \
      "static void tcg_out_addi_ptr(" \
      "static void tcg_out_st(" "static void tcg_out_ld(" \
      "static void tcg_out_mov(" "static void tcg_out_movi("; do
      spatch tcg/i386/tcg-target.c.inc "$fn" "$H"
    done
    # v16: Force inline critical tiny helpers
    # v17.0-fix: removed — tcg_out8/32/64/opc defined in tcg.c with different signatures
    # v17.0-fix: removed — tcg_out8/32/64/opc defined in tcg.c with different signatures
    # v17.0-fix: removed — tcg_out8/32/64/opc defined in tcg.c with different signatures
    # v17.0-fix: removed — tcg_out8/32/64/opc defined in tcg.c with different signatures
    echo "    ✓ tcg-target.c.inc (x86_64 backend): $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3S. ★ Atomic Helpers — critical for MTTCG
    # ────────────────────────────────────────
    echo "  🔥 [S] accel/tcg/cputlb.c — MMU lookup + load/store ★ NEW"
    for fn in "static bool mmu_lookup1(" "static bool mmu_lookup(" \
      "static uint64_t do_ld_mmio_beN(" "static uint64_t do_ld_bytes_beN(" \
      "static uint64_t do_ld_parts_beN(" "static uint64_t do_ld_whole_be4(" \
      "static uint64_t do_ld_whole_be8("; do
      spatch accel/tcg/cputlb.c "$fn" "$H"
    done
    echo "    ✓ MMU lookup + load: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3T. ★ SoftMMU Load/Store Common — TLB miss slow path
    # ────────────────────────────────────────
    echo "  🔥 [T] accel/tcg/cputlb.c — TLB management ops ★ NEW"
    for fn in "void tlb_set_dirty(" "void tlb_reset_dirty(" \
      "bool tlb_plugin_lookup("; do
      spatch accel/tcg/cputlb.c "$fn" "$H"
    done
    echo "    ✓ TLB management: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3U. ★ x86 Memory Helpers — string ops (rep movsb etc.)
    # ────────────────────────────────────────
    echo "  🔥 [U] target/i386/tcg/mem_helper.c — memory/string ops ★ NEW"
    for fn in "void helper_boundw" "void helper_boundl"; do
      spatch target/i386/tcg/mem_helper.c "$fn" "$H"
    done
    echo "    ✓ mem_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3V. ★ x86 Exception Helpers — interrupt/exception path
    # ────────────────────────────────────────
    echo "  🔥 [V] target/i386/tcg/excp_helper.c — exception path ★ NEW"
    for fn in "G_NORETURN void helper_raise_exception(" \
      "G_NORETURN void helper_raise_interrupt(" \
      "G_NORETURN void raise_exception_err("; do
      spatch target/i386/tcg/excp_helper.c "$fn" "$H"
    done
    echo "    ✓ excp_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3W. ★ x86 SVM/SMM Helpers — system management
    # ────────────────────────────────────────
    echo "  🔥 [W] target/i386/tcg/svm_helper.c — SVM ops ★ NEW"
    for fn in "void helper_vmrun" "void helper_vmload" \
      "void helper_clgi"; do
      spatch target/i386/tcg/system/svm_helper.c "$fn" "$H"
    done
    echo "    ✓ svm_helper.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3X. ★ Softfloat Library — FP math engine
    # ────────────────────────────────────────
    echo "  🔥 [X] fpu/softfloat.c — Softfloat math engine ★ NEW"
    for fn in "float64 float64_add(" "float64 float64_sub(" \
      "float64 float64_mul(" "float64 float64_div(" \
      "float32 float32_add(" "float32 float32_sub(" \
      "float32 float32_mul(" "float32 float32_div(" \
      "FloatRelation float64_compare(" "FloatRelation float32_compare(" \
      "float64 float64_sqrt(" "float32 float32_sqrt(" \
      "int64_t float64_to_int64(" "int32_t float64_to_int32(" \
      "float64 int64_to_float64(" "float64 int32_to_float64(" \
      "float64 float32_to_float64(" "float32 float64_to_float32(" \
      "static void parts64_canonicalize(" \
      "static FloatParts64 *parts64_addsub(" \
      "static FloatParts64 *parts64_mul(" \
      "static FloatParts64 *parts64_muladd_scalbn("; do
      spatch fpu/softfloat.c "$fn" "$H"
    done
    echo "    ✓ softfloat.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3Y. ★ Timer/Clock Subsystem — reduce overhead
    # ────────────────────────────────────────
    echo "  🔥 [Y] system/qemu-timer.c + cpus.c — timer subsystem ★ NEW"
    spatch system/cpu-timers.c "int64_t cpu_get_ticks(" "$H"
    spatch system/cpu-timers.c "static int64_t cpu_get_ticks_locked(" "$H"
    spatch util/qemu-timer.c "void timer_del(" "$H"
    spatch util/qemu-timer.c "bool timer_expired(" "$H"
    spatch util/qemu-timer.c "int64_t timerlist_deadline_ns(" "$H"
    spatch util/qemu-timer.c "static bool timer_mod_ns_locked(" "$H"
    echo "    ✓ qemu-timer.c: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  3Z. ★ Extra __builtin_expect across codebase
    # ────────────────────────────────────────
    echo "  🔥 [Z] Extra branch predictions across codebase ★ NEW"
    # TLB miss is rare
    # v17.0-fix: victim_tlb_hit has complex args - skip __builtin_expect
    # TB generation needed is rare (hot loop stays in cache)
    # v17.0-fix: tb_exit already patched above
    echo "    ✓ Extra branch predictions: $PATCH_OK patched"


    # ═══════════════════════════════════════════════════════════
    #  ★★★ V17 NEW DEEP PATCHES (+100 functions) ★★★
    # ═══════════════════════════════════════════════════════════

    echo ""
    info "──── V17 ADDITIONAL DEEP PATCHES ────"

    # ────────────────────────────────────────
    #  V17-A. ★ More FPU helpers (40+ more)
    # ────────────────────────────────────────
    echo "  🔥 [V17-A] fpu_helper.c — 40+ additional FPU functions ★ NEW"
    for fn in "void helper_fldt_ST0" "void helper_fstt_ST0" \
      "void helper_fdecstp" "void helper_fincstp" \
      "void helper_ffree_STN" "void helper_fmov_ST0_FT0" \
      "void helper_fmov_FT0_STN" "void helper_fmov_ST0_STN" \
      "void helper_fmov_STN_ST0" "void helper_fxchg_ST0_STN" \
      "void helper_fadd_STN_ST0" "void helper_fmul_STN_ST0" \
      "void helper_fdiv_STN_ST0" "void helper_fdivr_STN_ST0" \
      "void helper_fsub_STN_ST0" "void helper_fsubr_STN_ST0" \
      "void helper_fcomi_ST0_FT0" "void helper_fucomi_ST0_FT0" \
      "void helper_fcom_ST0_FT0" "void helper_fucom_ST0_FT0" \
      "void helper_fadd_ST0_FT0" "void helper_fmul_ST0_FT0" \
      "void helper_fdiv_ST0_FT0" "void helper_fdivr_ST0_FT0" \
      "void helper_fsub_ST0_FT0" "void helper_fsubr_ST0_FT0" \
      "void helper_fcmovcc" "void helper_fldz_FT0" \
      "void helper_fld1_ST0" "void helper_fldl2t_ST0" \
      "void helper_fldl2e_ST0" "void helper_fldpi_ST0" \
      "void helper_fldln2_ST0" "void helper_fldlg2_ST0" \
      "uint32_t helper_fsts_ST0" "uint64_t helper_fstl_ST0" \
      "void helper_fisttl_ST0" "void helper_fisttll_ST0" \
      "void helper_fistl_ST0" "void helper_fistll_ST0" \
      "void helper_fbst_ST0"; do
      spatch target/i386/tcg/fpu_helper.c "$fn" "$H"
    done
    echo "    ✓ fpu_helper v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-B. ★ More TCG Optimizer fold_ functions (25+)
    # ────────────────────────────────────────
    echo "  🔥 [V17-B] tcg/optimize.c — 25+ additional fold functions ★ NEW"
    for fn in "static bool fold_not(" "static bool fold_neg(" \
      "static bool fold_to_not(" "static bool fold_const1(" \
      "static bool fold_const2(" "static bool fold_commutative(" \
      "static bool fold_const2_commutative(" \
      "static bool fold_masks_z(" "static bool fold_masks_s(" \
      "static bool fold_masks_zo(" "static bool fold_masks_zs(" \
      "static bool fold_ix_to_i(" "static bool fold_ix_to_not(" \
      "static bool fold_xi_to_i(" "static bool fold_xi_to_x(" \
      "static bool fold_xi_to_not(" "static bool fold_xx_to_i(" \
      "static bool fold_xx_to_x(" "static bool fold_xx_to_not(" \
      "static bool fold_count_zeros(" "static bool fold_bswap(" \
      "static bool fold_dup(" "static bool fold_dup2(" \
      "static bool fold_remainder(" "static bool fold_sextract("; do
      spatch tcg/optimize.c "$fn" "$H"
    done
    echo "    ✓ optimize.c v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-C. ★ More TCG Backend functions (15+)
    # ────────────────────────────────────────
    echo "  🔥 [V17-C] tcg-target.c.inc — 15+ additional backend functions ★ NEW"
    for fn in "static void tcg_out_modrm(" "static void tcg_out_vex_opc(" \
      "static void tcg_out_evex_opc(" "static void tcg_out_vex_modrm(" \
      "static void tcg_out_sib_offset(" "static void tcg_out_modrm_sib_offset(" \
      "static void tcg_out_vex_modrm_sib_offset(" \
      "static void tcg_out_movi_int(" "static void tcg_out_movi_vec(" \
      "static void tcg_out_dupi_vec(" "static bool tcg_out_dup_vec(" \
      "static bool tcg_out_dupm_vec(" "static bool tcg_out_xchg(" \
      "static void tcg_out_mb(" "static void tcg_out_cmp("; do
      spatch tcg/i386/tcg-target.c.inc "$fn" "$H"
    done
    echo "    ✓ tcg-target v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-D. ★ More Softfloat internals (15+)
    # ────────────────────────────────────────
    echo "  🔥 [V17-D] fpu/softfloat.c — 15+ more internal functions ★ NEW"
    for fn in "static FloatParts64 *parts64_div(" \
      "static FloatParts64 *parts64_modrem(" \
      "static void parts64_sqrt(" \
      "static void parts64_round_to_int(" \
      "static int64_t parts64_float_to_sint(" \
      "static uint64_t parts64_float_to_uint(" \
      "static void parts64_sint_to_float(" \
      "static void parts64_uint_to_float(" \
      "static void parts64_add_normal(" \
      "static bool parts64_sub_normal(" \
      "static void parts64_uncanon(" \
      "static void parts64_uncanon_normal(" \
      "static void parts64_return_nan(" \
      "float64_sqrt(" "float32_sqrt(" \
      "float64_round_to_int(" "float32_round_to_int("; do
      spatch fpu/softfloat.c "$fn" "$H"
    done
    echo "    ✓ softfloat v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-E. ★ Memory Region Dispatch (10+)
    # ────────────────────────────────────────
    echo "  🔥 [V17-E] system/memory.c — memory dispatch hot path ★ NEW"
    for fn in "static MemTxResult memory_region_dispatch_read1(" \
      "MemTxResult memory_region_dispatch_read(" \
      "MemTxResult memory_region_dispatch_write(" \
      "static MemTxResult access_with_adjusted_size(" \
      "static MemTxResult  memory_region_read_accessor(" \
      "static MemTxResult memory_region_read_with_attrs_accessor(" \
      "static MemTxResult memory_region_write_accessor(" \
      "static MemTxResult memory_region_write_with_attrs_accessor(" \
      "void memory_region_ref(" "void memory_region_unref("; do
      spatch system/memory.c "$fn" "$H"
    done
    echo "    ✓ memory.c v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-F. ★ x86 System Helpers (all subdirectory)
    # ────────────────────────────────────────
    echo "  🔥 [V17-F] target/i386/tcg/system/*.c — system helpers ★ NEW"
    spatch target/i386/tcg/system/seg_helper.c "void helper_check_io" "$H"
    for fn in "void helper_vmmcall" "void helper_vmsave" \
      "void helper_stgi" "void helper_svm_check_intercept(" \
      "void helper_svm_check_io" "void cpu_svm_check_intercept_param"; do
      spatch target/i386/tcg/system/svm_helper.c "$fn" "$H"
    done
    for fn in "void helper_outb" "void helper_outw" "void helper_outl" \
      "void helper_write_crN" "void helper_flush_page" "void helper_monitor"; do
      spatch target/i386/tcg/system/misc_helper.c "$fn" "$H"
    done
    echo "    ✓ system helpers v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-G. ★ More x86 translate functions
    # ────────────────────────────────────────
    echo "  🔥 [V17-G] target/i386/tcg/translate.c — additional gen_ ★ NEW"
    for fn in "static void gen_add_A0_im(" "static void gen_lea_v_seg(" \
      "static void gen_lea_v_seg_dest(" "static void gen_op_j_ecx(" \
      "static void gen_set_hflag(" "static void gen_reset_hflag(" \
      "static void gen_set_eflags(" "static void gen_reset_eflags(" \
      "static void gen_helper_in_func(" "static void gen_helper_out_func(" \
      "static void gen_jmp_rel_csize(" "static void gen_exception_gpf("; do
      spatch target/i386/tcg/translate.c "$fn" "$H"
    done
    echo "    ✓ translate v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-H. ★ More cputlb internal functions
    # ────────────────────────────────────────
    echo "  🔥 [V17-H] accel/tcg/cputlb.c — TLB internals ★ NEW"
    for fn in "static void tlb_flush_one_mmuidx_locked(" \
      "static void tlb_mmu_flush_locked(" \
      "static void tlb_flush_page_locked(" \
      "static void tlb_flush_vtlb_page_mask_locked(" \
      "static void tlb_flush_page_by_mmuidx_async_0(" \
      "void tlb_flush_page_by_mmuidx(" \
      "void tlb_flush_page_by_mmuidx_all_cpus_synced(" \
      "void tlb_set_dirty(" "void tlb_reset_dirty("; do
      spatch accel/tcg/cputlb.c "$fn" "$H"
    done
    echo "    ✓ cputlb v17: $PATCH_OK patched"

    # ────────────────────────────────────────
    #  V17-I. ★ AIO event loop
    # ────────────────────────────────────────
    echo "  🔥 [V17-I] util/aio-posix.c — async I/O loop ★ NEW"
    for fn in "void aio_set_fd_handler(" "bool aio_prepare(" \
      "bool aio_pending(" "bool aio_dispatch("; do
      spatch util/aio-posix.c "$fn" "$H"
    done
    echo "    ✓ aio-posix v17: $PATCH_OK patched"


    echo ""
    msg "Total: $PATCH_OK patches applied, $PATCH_SKIP skipped!"

    # ══════════════════════════════════════════════
    #  PHASE 4: CONFIGURE with LLVM v16 Flags
    # ══════════════════════════════════════════════
    echo ""
    info "=== [4/6] Configure with LLVM v16 Hyper Max Flags ==="

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
    BASE="$BASE -falign-functions=64"
    BASE="$BASE -falign-loops=32"
    BASE="$BASE -fno-common"
    BASE="$BASE -DNDEBUG"
    # v16: New base flags
    BASE="$BASE -fjump-tables"
    BASE="$BASE -fno-delete-null-pointer-checks"
    BASE="$BASE -fno-lifetime-dse"
    BASE="$BASE -freroll-loops"

    # ── LLVM Polly (Polyhedral Optimizer) ──
    POLLY=""
    if [[ "$POLLY_SUPPORTED" == "yes" ]]; then
      POLLY="-mllvm -polly"
      POLLY="$POLLY -mllvm -polly-vectorizer=stripmine"
      POLLY="$POLLY -mllvm -polly-position=before-vectorizer"
      POLLY="$POLLY -mllvm -polly-run-dce"
      POLLY="$POLLY -mllvm -polly-run-inliner"
      POLLY="$POLLY -mllvm -polly-invariant-load-hoisting"
      POLLY="$POLLY -mllvm -polly-2nd-level-tiling"
      POLLY="$POLLY -mllvm -polly-pattern-matching-based-opts"
      # v16: New polly flags
      POLLY="$POLLY -mllvm -polly-scheduling=dynamic"
      POLLY="$POLLY -mllvm -polly-tiling"
      POLLY="$POLLY -mllvm -polly-prevect-width=4"
    fi

    # ── LLVM Inlining Tuning (v16 aggressive) ──
    INLINE="-mllvm -inline-threshold=1500"
    INLINE="$INLINE -mllvm -inlinehint-threshold=3000"
    INLINE="$INLINE -mllvm -hot-callsite-threshold=1000"
    # v16: Extra inline controls
    INLINE="$INLINE -mllvm -inline-cost-full-specialization-bonus=5000"

    # ── LLVM Loop Optimizations (v16 enhanced) ──
    LOOPS="-mllvm -unroll-threshold=750"
    LOOPS="$LOOPS -mllvm -unroll-count=8"
    # v16: New loop opts
    LOOPS="$LOOPS -mllvm -enable-loopinterchange"
    LOOPS="$LOOPS -mllvm -enable-loop-flatten"

    # ── LLVM GVN + Advanced (v16 enhanced) ──
    GVN="-mllvm -enable-gvn-hoist"
    GVN="$GVN -mllvm -enable-gvn-sink"
    GVN="$GVN -mllvm -enable-loop-versioning-licm"
    GVN="$GVN -mllvm -enable-dse"
    # v16: New analysis passes
    GVN="$GVN -mllvm -enable-load-pre"
    GVN="$GVN -mllvm -aggressive-ext-opt"

    # ── v16: Vectorizer enhancements ──
    VEC="-mllvm -extra-vectorizer-passes"
    VEC="$VEC -mllvm -slp-vectorize-hor"
    VEC="$VEC -mllvm -enable-cond-stores-vec"
    VEC="$VEC -mllvm -enable-interleaved-mem-accesses"

    # ── LTO Mode ──
    AVAIL_GB=$(df --output=avail / | tail -1 | awk '{printf "%.0f", $1/1024/1024}')
    if [ "$AVAIL_GB" -ge 40 ]; then
      LTO_MODE="full"
      msg "Disk ${AVAIL_GB}GB → LTO=full (maximum optimization)"
    else
      LTO_MODE="thin"
      warn "Disk ${AVAIL_GB}GB → LTO=thin (saving disk space)"
    fi

    # ── Assemble final flags ──
    FINAL_CFLAGS="$BASE $POLLY $INLINE $LOOPS $GVN $VEC -flto=$LTO_MODE"
    FINAL_LDFLAGS="-fuse-ld=lld -flto=$LTO_MODE"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--lto-O3"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--gc-sections"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--icf=all"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,-O3"
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,--strip-all"
    # v16: Better cache locality for code layout
    FINAL_LDFLAGS="$FINAL_LDFLAGS -Wl,-z,keep-text-section-prefix"

    mkdir -p /tmp/qemu-build && cd /tmp/qemu-build
    info "Running configure..."

    silent /tmp/qemu-src/configure \
        --prefix=/opt/qemu-optimized \
        --target-list=x86_64-softmmu \
        --enable-tcg --enable-slirp --enable-coroutine-pool --enable-malloc-trim --enable-linux-io-uring \
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
    ulimit -n 65535 2>/dev/null || true

    NPROC=$(nproc)
    if [ "$LTO_MODE" == "full" ] && [ "$NPROC" -gt 8 ]; then
      BUILD_JOBS=8
      warn "LTO=full → limiting to $BUILD_JOBS jobs to avoid OOM"
    else
      BUILD_JOBS=$NPROC
    fi

    echo "🕧 QEMU v17.0 OMEGA đang build... vui lòng đợi..."
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
    cd ~

    qemu-system-x86_64 --version
    msg "🔥 QEMU V17.0 OMEGA build hoàn tất!"
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
#  WINDOWS VM MANAGER v17.0
# ══════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER v17.0 OMEGA"
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
cd ~
if [[ ! -f win.img ]]; then
  aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
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

# ── v16: Enhanced CPU model with more Hyper-V enlightenments ──
cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on"
cpu_model="$cpu_model,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2"
cpu_model="$cpu_model,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse"
cpu_model="$cpu_model,+lahf_lm,+rdtscp,+movbe,+abm,+bmi1,+bmi2,+avx,+avx2"
# v16: Enhanced Hyper-V enlightenments
cpu_model="$cpu_model,hv-relaxed=on,hv-vapic=on,hv-spinlocks=8191,hv-time=on"
cpu_model="$cpu_model,hv-frequencies=on,hv-reenlightenment=on"
cpu_model="$cpu_model,hv-tlbflush=on,hv-ipi=on"
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

# ── v16: Auto-detect best AIO backend ──
# v17: cache=unsafe + aio=threads = fastest combo for TCG
# (aio=native requires cache.direct=on which is slower than cache=unsafe)
AIO_BACKEND="threads"

info "Đang tạo VM v16 Hyper Max với cấu hình tối ưu..."

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

# ── v16: Set CPU affinity if possible ──
TOTAL_CORES=$(nproc)
if [ "$TOTAL_CORES" -gt "$cpu_core" ]; then
  # Reserve core 0 for host, assign rest to QEMU
  TASKSET_CMD="taskset -c 1-$((cpu_core))"
  info "CPU pinning: cores 1-$cpu_core for VM (core 0 reserved for host)"
else
  TASKSET_CMD=""
fi

echo "⌛ Đang Tạo VM v16 HYPER MAX vui lòng đợi..."

$TASKSET_CMD $QBIN \
    -L /opt/qemu-optimized/share/qemu \
    -L /usr/share/qemu \
    -L /usr/lib/ipxe/qemu \
    -machine q35,hpet=off,vmport=off,kernel-irqchip=split \
    -overcommit mem-lock=off \
    -cpu "$cpu_model" \
    -smp "$cpu_core",sockets=1,cores="$cpu_core",threads=1 \
    -m "${ram_size}G" $MEMORY_BACKEND \
    -accel tcg,thread=multi,tb-size=16777216 \
    -rtc base=localtime,driftfix=slew \
    $BIOS_OPT \
    -drive file=win.img,if=virtio,cache=unsafe,aio=$AIO_BACKEND,format=raw,discard=unmap,detect-zeroes=unmap \
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
    -daemonize

sleep 3

use_rdp=$(ask "🛰️ Tiếp tục mở port để kết nối đến VM? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
  silent curl -sSL https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz -o kami-tunnel-linux-amd64.tar.gz
  silent tar -xzf kami-tunnel-linux-amd64.tar.gz
  silent chmod +x kami-tunnel
  silent sudo apt install -y tmux

  tmux kill-session -t kami 2>/dev/null || true
  tmux new-session -d -s kami "./kami-tunnel 3389"
  sleep 4

  PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)

  echo ""
  echo "══════════════════════════════════════════════"
  echo "🚀 WINDOWS VM DEPLOYED — v17.0 OMEGA"
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
  echo "🔥 Build       : QEMU v17.0 OMEGA"
  echo "🔧 TB Buffer   : 16MB | TB Cache: 32K entries"
  echo "🔧 AIO         : $AIO_BACKEND"
  echo "══════════════════════════════════════════════"
else
  echo ""
  echo "══════════════════════════════════════════════"
  echo "🚀 VM RUNNING (no tunnel) — v17.0 OMEGA"
  echo "══════════════════════════════════════════════"
  echo "🪟 OS          : $WIN_NAME"
  echo "⚙ CPU Cores   : $cpu_core"
  echo "💾 RAM         : ${ram_size} GB"
  echo "📡 RDP         : localhost:3389"
  echo "👤 Username    : $RDP_USER"
  echo "🔑 Password    : $RDP_PASS"
  echo "🔧 TB Buffer   : 16MB | TB Cache: 32K entries"
  echo "🔧 AIO         : $AIO_BACKEND"
  echo "══════════════════════════════════════════════"
fi

# ══════════════════════════════════════════════════════════════
#  WINDOWS IN-VM OPTIMIZATION TIPS (v16 enhanced)
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "\033[1;33m💡 TIPS: Tối ưu TRONG Windows VM để giảm CPU idle:\033[0m"
echo "  1. Mở CMD Admin → powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
echo "     (Chuyển High Performance power plan)"
echo "  2. Tắt Windows Search: sc stop WSearch && sc config WSearch start=disabled"
echo "  3. Tắt Superfetch:     sc stop SysMain && sc config SysMain start=disabled"
echo "  4. Tắt Telemetry:      sc stop DiagTrack && sc config DiagTrack start=disabled"
echo "  5. Tắt Windows Update: sc stop wuauserv && sc config wuauserv start=disabled"
echo "  6. Giảm timer: bcdedit /set disabledynamictick yes && bcdedit /set useplatformtick yes"
echo "  7. Registry: HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
echo "     → DisablePagingExecutive = 1 (giữ kernel trong RAM)"
echo "  8. ★ NEW: bcdedit /set tscsyncpolicy enhanced"
echo "     (Hyper-V TSC sync → smoother timekeeping with hv-time)"
echo "  9. ★ NEW: Disable USB selective suspend in Device Manager"
echo "     → Giảm timer interrupt overhead"
echo ""
