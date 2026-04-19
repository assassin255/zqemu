#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  ZQEMU GPU Emulate Launcher                                            ║
# ║  Wrapper for qemu-system-x86_64 with --emulategpu-id support          ║
# ║                                                                        ║
# ║  Usage:                                                                ║
# ║    qemu-gpu-emulate.sh --emulategpu-id "Nvidia RTX 4090" [qemu opts]  ║
# ║    qemu-gpu-emulate.sh --list-gpus                                     ║
# ║    qemu-gpu-emulate.sh --emulategpu-id "RTX 3080" \                   ║
# ║        -m 8G -smp 4 -drive file=disk.img,if=virtio ...                ║
# ╚══════════════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="${SCRIPT_DIR}/../share"

# ── Colors ──
RST='\033[0m'; BLD='\033[1m'; RED='\033[1;31m'; GRN='\033[1;32m'
YLW='\033[1;33m'; BLU='\033[1;34m'; CYN='\033[1;36m'; DIM='\033[2m'

err()  { echo -e "${RED}[ERR] $1${RST}" >&2; }
msg()  { echo -e "${GRN}[OK] $1${RST}"; }
info() { echo -e "${CYN}[INFO] $1${RST}"; }

# ── Load GPU database ──
GPU_DB_PATH=""
for p in \
    "$SHARE_DIR/gpu-database.sh" \
    "$SCRIPT_DIR/../share/gpu-database.sh" \
    "$SCRIPT_DIR/patches/gpu-database.sh" \
    "$(dirname "$SCRIPT_DIR")/patches/gpu-database.sh" \
    "/opt/qemu-gpu-emulate/share/gpu-database.sh"; do
    if [[ -f "$p" ]]; then
        GPU_DB_PATH="$p"
        break
    fi
done

if [[ -z "$GPU_DB_PATH" ]]; then
    err "gpu-database.sh not found! Ensure it is in the share/ or patches/ directory."
    exit 1
fi

source "$GPU_DB_PATH"

# ── Find QEMU binary ──
QEMU_BIN=""
for q in \
    "$SCRIPT_DIR/qemu-system-x86_64" \
    "/opt/qemu-gpu-emulate/bin/qemu-system-x86_64" \
    "/opt/qemu-optimized/bin/qemu-system-x86_64"; do
    if [[ -x "$q" ]]; then
        QEMU_BIN="$q"
        break
    fi
done

if [[ -z "$QEMU_BIN" ]]; then
    QEMU_BIN=$(command -v qemu-system-x86_64 2>/dev/null || true)
fi

if [[ -z "$QEMU_BIN" ]]; then
    err "qemu-system-x86_64 not found! Build it first with zv21-gpu-emulate.sh"
    exit 1
fi

# ── Usage ──
usage() {
    echo -e "${BLD}ZQEMU GPU Emulate Launcher${RST}"
    echo ""
    echo "Usage:"
    echo "  $(basename "$0") --emulategpu-id \"<GPU Name>\" [qemu-system-x86_64 options...]"
    echo "  $(basename "$0") --list-gpus"
    echo "  $(basename "$0") --help"
    echo ""
    echo "Options:"
    echo "  --emulategpu-id \"<name>\"   Emulate the specified NVIDIA GPU"
    echo "  --list-gpus                List all available GPU models"
    echo "  --gpu-vram <MB>            Override VRAM size (in MB)"
    echo "  --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") --emulategpu-id \"Nvidia RTX 4090\" -m 8G -smp 4 -drive file=disk.img,if=virtio"
    echo "  $(basename "$0") --emulategpu-id \"RTX 3080\" --gpu-vram 12288 -m 4G -accel tcg"
    echo "  $(basename "$0") --emulategpu-id \"A100\" -m 16G -smp 8 -nographic"
    echo ""
    echo "The --emulategpu-id flag adds a PCI device that presents itself as the"
    echo "specified NVIDIA GPU to the guest OS. The guest will see the correct"
    echo "PCI vendor/device IDs in lspci and Device Manager."
    echo ""
    echo "NOTE: This is PCI identity emulation only. The device does not provide"
    echo "actual GPU compute or rendering capabilities. It is useful for testing"
    echo "GPU-aware software, driver installation, and PCI enumeration."
}

# ── Parse our custom arguments, pass everything else to QEMU ──
GPU_NAME=""
GPU_VRAM_OVERRIDE=""
QEMU_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emulategpu-id)
            if [[ $# -lt 2 ]]; then
                err "--emulategpu-id requires a GPU name argument"
                exit 1
            fi
            GPU_NAME="$2"
            shift 2
            ;;
        --list-gpus)
            gpu_list_all
            exit 0
            ;;
        --gpu-vram)
            if [[ $# -lt 2 ]]; then
                err "--gpu-vram requires a value in MB"
                exit 1
            fi
            GPU_VRAM_OVERRIDE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            QEMU_ARGS+=("$1")
            shift
            ;;
    esac
done

# ── If no GPU specified, just pass through to QEMU ──
if [[ -z "$GPU_NAME" ]]; then
    info "No --emulategpu-id specified, running plain QEMU"
    exec "$QEMU_BIN" "${QEMU_ARGS[@]}"
fi

# ── Look up GPU in database ──
GPU_ENTRY=$(gpu_lookup "$GPU_NAME" || true)

if [[ -z "$GPU_ENTRY" ]]; then
    err "GPU '$GPU_NAME' not found in database!"
    echo ""
    echo "Try one of these:"
    gpu_list_all
    exit 1
fi

# Parse the entry: device_id:subsystem_id:vram_mb:display_name
IFS=':' read -r GPU_DEV_ID GPU_SUB_ID GPU_VRAM GPU_DISPLAY_NAME <<< "$GPU_ENTRY"

# Apply VRAM override if specified
if [[ -n "$GPU_VRAM_OVERRIDE" ]]; then
    GPU_VRAM="$GPU_VRAM_OVERRIDE"
fi

echo ""
echo -e "${BLD}========================================${RST}"
echo -e "${CYN}  ZQEMU GPU Emulation${RST}"
echo -e "${BLD}========================================${RST}"
echo -e "  GPU Model  : ${BLD}$GPU_DISPLAY_NAME${RST}"
echo -e "  Device ID  : ${DIM}0x$GPU_DEV_ID${RST}"
echo -e "  Subsystem  : ${DIM}0x$GPU_SUB_ID${RST}"
echo -e "  VRAM       : ${BLD}$((GPU_VRAM / 1024))GB${RST} (${GPU_VRAM}MB)"
echo -e "  QEMU       : ${DIM}$QEMU_BIN${RST}"
echo -e "${BLD}========================================${RST}"
echo ""

# ── Build the -device argument ──
GPU_DEVICE_ARG="emulated-nvidia-gpu"
GPU_DEVICE_ARG="$GPU_DEVICE_ARG,gpu_device_id=0x${GPU_DEV_ID}"
GPU_DEVICE_ARG="$GPU_DEVICE_ARG,gpu_subsystem_id=0x${GPU_SUB_ID}"
GPU_DEVICE_ARG="$GPU_DEVICE_ARG,vram_size_mb=${GPU_VRAM}"
GPU_DEVICE_ARG="$GPU_DEVICE_ARG,gpu_name=${GPU_DISPLAY_NAME}"

info "Starting QEMU with emulated $GPU_DISPLAY_NAME..."
info "Device args: -device $GPU_DEVICE_ARG"
echo ""

# ── Determine BIOS paths ──
BIOS_PATHS=()
for bp in \
    /opt/qemu-gpu-emulate/share/qemu \
    /opt/qemu-optimized/share/qemu \
    /usr/share/qemu \
    /usr/lib/ipxe/qemu; do
    if [[ -d "$bp" ]]; then
        BIOS_PATHS+=("-L" "$bp")
    fi
done

# ── Execute QEMU with the emulated GPU ──
exec "$QEMU_BIN" \
    "${BIOS_PATHS[@]}" \
    -device "$GPU_DEVICE_ARG" \
    "${QEMU_ARGS[@]}"
