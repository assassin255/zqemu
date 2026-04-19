#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  ZQEMU GPU Database — NVIDIA GPU PCI Device ID Mapping
#  Used by qemu-gpu-emulate.sh and zv21-gpu-emulate.sh
#
#  Format: gpu_db["<lowercase-name>"]="<device_id>:<subsystem_id>:<vram_mb>:<name>"
#  Vendor ID is always 0x10DE (NVIDIA)
# ═══════════════════════════════════════════════════════════════════

declare -A gpu_db

# ── GeForce RTX 40 Series (Ada Lovelace) ──
gpu_db["rtx 4090"]="2684:1612:24576:NVIDIA GeForce RTX 4090"
gpu_db["nvidia rtx 4090"]="2684:1612:24576:NVIDIA GeForce RTX 4090"
gpu_db["geforce rtx 4090"]="2684:1612:24576:NVIDIA GeForce RTX 4090"
gpu_db["rtx 4080 super"]="2702:1612:16384:NVIDIA GeForce RTX 4080 SUPER"
gpu_db["rtx 4080"]="2786:1612:16384:NVIDIA GeForce RTX 4080"
gpu_db["nvidia rtx 4080"]="2786:1612:16384:NVIDIA GeForce RTX 4080"
gpu_db["rtx 4070 ti super"]="2705:1612:16384:NVIDIA GeForce RTX 4070 Ti SUPER"
gpu_db["rtx 4070 ti"]="2782:1612:12288:NVIDIA GeForce RTX 4070 Ti"
gpu_db["rtx 4070 super"]="2783:1612:12288:NVIDIA GeForce RTX 4070 SUPER"
gpu_db["rtx 4070"]="2786:1612:12288:NVIDIA GeForce RTX 4070"
gpu_db["rtx 4060 ti"]="2803:1612:8192:NVIDIA GeForce RTX 4060 Ti"
gpu_db["rtx 4060"]="2882:1612:8192:NVIDIA GeForce RTX 4060"

# ── GeForce RTX 30 Series (Ampere) ──
gpu_db["rtx 3090 ti"]="2203:1612:24576:NVIDIA GeForce RTX 3090 Ti"
gpu_db["rtx 3090"]="2204:1612:24576:NVIDIA GeForce RTX 3090"
gpu_db["nvidia rtx 3090"]="2204:1612:24576:NVIDIA GeForce RTX 3090"
gpu_db["rtx 3080 ti"]="2208:1612:12288:NVIDIA GeForce RTX 3080 Ti"
gpu_db["rtx 3080"]="2206:1612:10240:NVIDIA GeForce RTX 3080"
gpu_db["nvidia rtx 3080"]="2206:1612:10240:NVIDIA GeForce RTX 3080"
gpu_db["rtx 3070 ti"]="2482:1612:8192:NVIDIA GeForce RTX 3070 Ti"
gpu_db["rtx 3070"]="2484:1612:8192:NVIDIA GeForce RTX 3070"
gpu_db["rtx 3060 ti"]="2486:1612:8192:NVIDIA GeForce RTX 3060 Ti"
gpu_db["rtx 3060"]="2503:1612:12288:NVIDIA GeForce RTX 3060"
gpu_db["rtx 3050"]="2507:1612:8192:NVIDIA GeForce RTX 3050"

# ── GeForce RTX 20 Series (Turing) ──
gpu_db["rtx 2080 ti"]="1e04:1612:11264:NVIDIA GeForce RTX 2080 Ti"
gpu_db["rtx 2080 super"]="1e81:1612:8192:NVIDIA GeForce RTX 2080 SUPER"
gpu_db["rtx 2080"]="1e82:1612:8192:NVIDIA GeForce RTX 2080"
gpu_db["rtx 2070 super"]="1e84:1612:8192:NVIDIA GeForce RTX 2070 SUPER"
gpu_db["rtx 2070"]="1f02:1612:8192:NVIDIA GeForce RTX 2070"
gpu_db["rtx 2060 super"]="1f06:1612:8192:NVIDIA GeForce RTX 2060 SUPER"
gpu_db["rtx 2060"]="1f08:1612:6144:NVIDIA GeForce RTX 2060"

# ── GeForce GTX 16 Series (Turing) ──
gpu_db["gtx 1660 ti"]="2182:1612:6144:NVIDIA GeForce GTX 1660 Ti"
gpu_db["gtx 1660 super"]="21c4:1612:6144:NVIDIA GeForce GTX 1660 SUPER"
gpu_db["gtx 1660"]="2184:1612:6144:NVIDIA GeForce GTX 1660"
gpu_db["gtx 1650 super"]="2187:1612:4096:NVIDIA GeForce GTX 1650 SUPER"
gpu_db["gtx 1650"]="1f82:1612:4096:NVIDIA GeForce GTX 1650"

# ── GeForce GTX 10 Series (Pascal) ──
gpu_db["gtx 1080 ti"]="1b06:1612:11264:NVIDIA GeForce GTX 1080 Ti"
gpu_db["gtx 1080"]="1b80:1612:8192:NVIDIA GeForce GTX 1080"
gpu_db["gtx 1070 ti"]="1b82:1612:8192:NVIDIA GeForce GTX 1070 Ti"
gpu_db["gtx 1070"]="1b81:1612:8192:NVIDIA GeForce GTX 1070"
gpu_db["gtx 1060"]="1c03:1612:6144:NVIDIA GeForce GTX 1060"
gpu_db["gtx 1050 ti"]="1c82:1612:4096:NVIDIA GeForce GTX 1050 Ti"
gpu_db["gtx 1050"]="1c81:1612:2048:NVIDIA GeForce GTX 1050"

# ── GeForce RTX 50 Series (Blackwell) ──
gpu_db["rtx 5090"]="2b85:1612:32768:NVIDIA GeForce RTX 5090"
gpu_db["nvidia rtx 5090"]="2b85:1612:32768:NVIDIA GeForce RTX 5090"
gpu_db["rtx 5080"]="2b87:1612:16384:NVIDIA GeForce RTX 5080"
gpu_db["rtx 5070 ti"]="2b89:1612:16384:NVIDIA GeForce RTX 5070 Ti"
gpu_db["rtx 5070"]="2b8b:1612:12288:NVIDIA GeForce RTX 5070"

# ── Data Center / Professional (selected) ──
gpu_db["a100"]="20b0:1612:81920:NVIDIA A100"
gpu_db["nvidia a100"]="20b0:1612:81920:NVIDIA A100"
gpu_db["h100"]="2330:1612:81920:NVIDIA H100"
gpu_db["nvidia h100"]="2330:1612:81920:NVIDIA H100"
gpu_db["l40"]="26b5:1612:49152:NVIDIA L40"
gpu_db["nvidia l40"]="26b5:1612:49152:NVIDIA L40"
gpu_db["t4"]="1eb8:1612:16384:NVIDIA T4"
gpu_db["nvidia t4"]="1eb8:1612:16384:NVIDIA T4"
gpu_db["v100"]="1db4:1612:32768:NVIDIA V100"
gpu_db["nvidia v100"]="1db4:1612:32768:NVIDIA V100"
gpu_db["a40"]="2235:1612:49152:NVIDIA A40"
gpu_db["nvidia a40"]="2235:1612:49152:NVIDIA A40"
gpu_db["rtx a6000"]="2230:1612:49152:NVIDIA RTX A6000"
gpu_db["rtx a5000"]="2231:1612:24576:NVIDIA RTX A5000"
gpu_db["rtx a4000"]="24b0:1612:16384:NVIDIA RTX A4000"

# ── Quadro (Legacy Professional) ──
gpu_db["quadro rtx 8000"]="1e30:1612:49152:NVIDIA Quadro RTX 8000"
gpu_db["quadro rtx 6000"]="1e30:1612:24576:NVIDIA Quadro RTX 6000"
gpu_db["quadro rtx 5000"]="1eb0:1612:16384:NVIDIA Quadro RTX 5000"
gpu_db["quadro p6000"]="1b30:1612:24576:NVIDIA Quadro P6000"

# ═══════════════════════════════════════════════════════════════════
#  Lookup function
# ═══════════════════════════════════════════════════════════════════
gpu_lookup() {
    local query="${1,,}"  # lowercase
    query="${query#nvidia }"  # strip leading "nvidia " if present
    query="${query#geforce }"  # strip leading "geforce " if present

    # Try exact match first
    if [[ -n "${gpu_db[$query]+x}" ]]; then
        echo "${gpu_db[$query]}"
        return 0
    fi

    # Try with "nvidia " prefix
    if [[ -n "${gpu_db[nvidia $query]+x}" ]]; then
        echo "${gpu_db[nvidia $query]}"
        return 0
    fi

    # Try with "geforce " prefix
    if [[ -n "${gpu_db[geforce $query]+x}" ]]; then
        echo "${gpu_db[geforce $query]}"
        return 0
    fi

    # Fuzzy search - find partial matches
    local best_match=""
    for key in "${!gpu_db[@]}"; do
        if [[ "$key" == *"$query"* ]]; then
            best_match="${gpu_db[$key]}"
            break
        fi
    done

    if [[ -n "$best_match" ]]; then
        echo "$best_match"
        return 0
    fi

    return 1
}

# List all available GPUs
gpu_list_all() {
    echo "Available NVIDIA GPUs for emulation:"
    echo "═══════════════════════════════════════════════════════════"
    printf "%-30s %-10s %-8s\n" "GPU Name" "DeviceID" "VRAM"
    echo "───────────────────────────────────────────────────────────"

    # Collect unique entries
    declare -A seen
    for key in $(echo "${!gpu_db[@]}" | tr ' ' '\n' | sort); do
        local val="${gpu_db[$key]}"
        local dev_id=$(echo "$val" | cut -d: -f1)
        if [[ -z "${seen[$dev_id]+x}" ]]; then
            seen[$dev_id]=1
            local name=$(echo "$val" | cut -d: -f4)
            local vram=$(echo "$val" | cut -d: -f3)
            local vram_gb=$((vram / 1024))
            printf "%-30s 0x%-8s %dGB\n" "$name" "$dev_id" "$vram_gb"
        fi
    done
    echo "═══════════════════════════════════════════════════════════"
}
