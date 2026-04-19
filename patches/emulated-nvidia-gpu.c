/*
 * Emulated NVIDIA GPU — PCI device for QEMU TCG
 *
 * This device presents itself as an NVIDIA GPU to the guest OS via PCI
 * configuration space (vendor/device/subsystem IDs). It provides:
 *
 *   - Correct NVIDIA PCI vendor ID (0x10DE)
 *   - Configurable device ID matching real NVIDIA GPUs
 *   - Basic MMIO register BAR (BAR0) for GPU control registers
 *   - VRAM BAR (BAR1) as a memory-mapped framebuffer region
 *   - MSI interrupt support
 *   - PCI Express capability
 *   - Basic register read/write for driver probing
 *
 * This is NOT a functional GPU — it does not execute shaders or render
 * graphics. Its purpose is to make the guest OS detect and enumerate
 * an NVIDIA GPU on the PCI bus, which is useful for:
 *   - Testing GPU-aware software in TCG environments
 *   - Driver installation testing
 *   - PCI enumeration and device management testing
 *
 * Usage:
 *   -device emulated-nvidia-gpu,gpu_device_id=0x2684,vram_size_mb=24576
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2025 ZQEMU Project
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qemu/log.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msi.h"
#include "hw/pci/pcie.h"
#include "hw/qdev-properties.h"
#include "migration/vmstate.h"
#include "qapi/error.h"

#define TYPE_EMULATED_NVIDIA_GPU "emulated-nvidia-gpu"
#define EMULATED_NVIDIA_GPU(obj) \
    OBJECT_CHECK(EmulatedNvidiaGPUState, (obj), TYPE_EMULATED_NVIDIA_GPU)

/* NVIDIA PCI Vendor ID */
#define NVIDIA_VENDOR_ID          0x10DE

/* Default: RTX 4090 */
#define DEFAULT_GPU_DEVICE_ID     0x2684
#define DEFAULT_SUBSYSTEM_ID      0x1612
#define DEFAULT_VRAM_SIZE_MB      24576

/* BAR sizes */
#define GPU_MMIO_BAR_SIZE         (16 * MiB)   /* BAR0: GPU registers */
#define GPU_VRAM_BAR_MIN          (256 * MiB)  /* BAR1: minimum VRAM region */

/* Register offsets (BAR0 MMIO space) */
#define NV_PMC_BOOT_0             0x00000000   /* GPU identification */
#define NV_PMC_BOOT_1             0x00000004   /* Revision */
#define NV_PMC_ENABLE             0x00000200   /* Engine enable */
#define NV_PMC_INTR_0             0x00000100   /* Interrupt status */
#define NV_PMC_INTR_EN_0          0x00000140   /* Interrupt enable */
#define NV_PBUS_PCI_NV_0          0x00001800   /* PCI config mirror */
#define NV_PBUS_PCI_NV_1          0x00001804
#define NV_PBUS_PCI_NV_2          0x00001808
#define NV_PFB_CFG0               0x00100C10   /* Framebuffer config */
#define NV_PFB_CSTATUS            0x0010020C   /* FB status (VRAM size) */
#define NV_PDISP_FE_HW_SYS_CAP   0x00610010   /* Display caps */
#define NV_PTIMER_TIME_0          0x00009400   /* Timer low */
#define NV_PTIMER_TIME_1          0x00009410   /* Timer high */
#define NV_FUSE_OPT_GPU_INFO     0x00021C00   /* GPU fuse info */
#define NV_GPU_TEMP               0x00020400   /* GPU temperature */

/* Maximum register space we handle */
#define NV_MMIO_MAX               0x01000000   /* 16 MB */

typedef struct EmulatedNvidiaGPUState {
    PCIDevice parent_obj;

    /* Configuration properties */
    uint32_t gpu_device_id;
    uint32_t gpu_subsystem_id;
    uint32_t vram_size_mb;
    char     *gpu_name;

    /* Memory regions */
    MemoryRegion mmio_bar;     /* BAR0: GPU registers */
    MemoryRegion vram_bar;     /* BAR1: VRAM / framebuffer */

    /* Emulated register state */
    uint32_t intr_status;
    uint32_t intr_enable;
    uint32_t engine_enable;
    uint32_t boot_id;

    /* Timer for NV_PTIMER */
    int64_t timer_base_ns;
} EmulatedNvidiaGPUState;

/* ════════════════════════════════════════════════════════════════
 *  BAR0 — GPU Register MMIO (read)
 * ════════════════════════════════════════════════════════════════ */
static uint64_t emulated_nvidia_gpu_mmio_read(void *opaque,
                                               hwaddr addr,
                                               unsigned size)
{
    EmulatedNvidiaGPUState *s = EMULATED_NVIDIA_GPU(opaque);

    switch (addr) {
    case NV_PMC_BOOT_0:
        /*
         * Boot register: encodes chip ID.
         * Upper 8 bits = architecture, lower bits = implementation.
         * We encode the device_id in bits [27:20] as a fake chip ID.
         */
        return (s->gpu_device_id << 4) | 0xA1;

    case NV_PMC_BOOT_1:
        /* Revision: report as rev A1 */
        return 0x000000A1;

    case NV_PMC_ENABLE:
        return s->engine_enable;

    case NV_PMC_INTR_0:
        return s->intr_status;

    case NV_PMC_INTR_EN_0:
        return s->intr_enable;

    case NV_PBUS_PCI_NV_0:
        /* Mirror of PCI config vendor/device */
        return (s->gpu_device_id << 16) | NVIDIA_VENDOR_ID;

    case NV_PBUS_PCI_NV_1:
        /* PCI status/command mirror */
        return 0x00100006;

    case NV_PBUS_PCI_NV_2:
        /* Class code: VGA-compatible controller (0x030000) + rev */
        return 0x030000A1;

    case NV_PFB_CFG0:
        /* Framebuffer config — report VRAM type as GDDR6X */
        return 0x00000045;

    case NV_PFB_CSTATUS:
        /* Report configured VRAM size in bytes */
        return (uint32_t)((uint64_t)s->vram_size_mb * 1024ULL * 1024ULL);

    case NV_PDISP_FE_HW_SYS_CAP:
        /* Display capabilities: report 4 heads */
        return 0x00000004;

    case NV_PTIMER_TIME_0: {
        /* Low 32 bits of nanosecond timer */
        int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
        return (uint32_t)(now - s->timer_base_ns);
    }

    case NV_PTIMER_TIME_1: {
        /* High 32 bits of nanosecond timer */
        int64_t now = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
        return (uint32_t)((now - s->timer_base_ns) >> 32);
    }

    case NV_FUSE_OPT_GPU_INFO:
        /* Fuse info: report max TPC count based on VRAM tier */
        if (s->vram_size_mb >= 24576) return 0x00000080;  /* High-end */
        if (s->vram_size_mb >= 12288) return 0x00000040;  /* Mid-range */
        return 0x00000020;                                  /* Entry */

    case NV_GPU_TEMP:
        /* Report a fake temperature of 45C (in units of 0.5C) */
        return 90;

    default:
        /*
         * For unhandled registers: return 0.
         * Real NVIDIA GPUs have thousands of registers; we only
         * emulate the ones needed for basic driver probing.
         */
        qemu_log_mask(LOG_UNIMP,
                      "emulated-nvidia-gpu: unhandled read at 0x%" HWADDR_PRIx
                      " (size=%u)\n", addr, size);
        return 0;
    }
}

/* ════════════════════════════════════════════════════════════════
 *  BAR0 — GPU Register MMIO (write)
 * ════════════════════════════════════════════════════════════════ */
static void emulated_nvidia_gpu_mmio_write(void *opaque,
                                            hwaddr addr,
                                            uint64_t val,
                                            unsigned size)
{
    EmulatedNvidiaGPUState *s = EMULATED_NVIDIA_GPU(opaque);

    switch (addr) {
    case NV_PMC_ENABLE:
        s->engine_enable = (uint32_t)val;
        break;

    case NV_PMC_INTR_0:
        /* Write-1-to-clear interrupt status */
        s->intr_status &= ~(uint32_t)val;
        break;

    case NV_PMC_INTR_EN_0:
        s->intr_enable = (uint32_t)val;
        break;

    default:
        qemu_log_mask(LOG_UNIMP,
                      "emulated-nvidia-gpu: unhandled write at 0x%" HWADDR_PRIx
                      " val=0x%" PRIx64 " (size=%u)\n", addr, val, size);
        break;
    }
}

static const MemoryRegionOps emulated_nvidia_gpu_mmio_ops = {
    .read = emulated_nvidia_gpu_mmio_read,
    .write = emulated_nvidia_gpu_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

/* ════════════════════════════════════════════════════════════════
 *  BAR1 — VRAM (simple read/write memory)
 * ════════════════════════════════════════════════════════════════ */
/* BAR1 is backed by plain RAM — no special ops needed */

/* ════════════════════════════════════════════════════════════════
 *  Device lifecycle
 * ════════════════════════════════════════════════════════════════ */
static void emulated_nvidia_gpu_realize(PCIDevice *pci_dev, Error **errp)
{
    EmulatedNvidiaGPUState *s = EMULATED_NVIDIA_GPU(pci_dev);
    uint64_t vram_bar_size;

    /* Set PCI identification */
    pci_config_set_vendor_id(pci_dev->config, NVIDIA_VENDOR_ID);
    pci_config_set_device_id(pci_dev->config, s->gpu_device_id);

    /* Class: VGA-compatible controller */
    pci_config_set_class(pci_dev->config, PCI_CLASS_DISPLAY_VGA);
    pci_config_set_revision(pci_dev->config, 0xA1);

    /* Subsystem IDs */
    pci_set_word(pci_dev->config + PCI_SUBSYSTEM_VENDOR_ID, NVIDIA_VENDOR_ID);
    pci_set_word(pci_dev->config + PCI_SUBSYSTEM_ID, s->gpu_subsystem_id);

    /* BAR0: MMIO registers (16 MB, non-prefetchable) */
    memory_region_init_io(&s->mmio_bar, OBJECT(s),
                          &emulated_nvidia_gpu_mmio_ops, s,
                          "emulated-nvidia-gpu-mmio",
                          GPU_MMIO_BAR_SIZE);
    pci_register_bar(pci_dev, 0,
                     PCI_BASE_ADDRESS_SPACE_MEMORY |
                     PCI_BASE_ADDRESS_MEM_TYPE_32,
                     &s->mmio_bar);

    /* BAR1: VRAM (prefetchable, 64-bit capable) */
    vram_bar_size = (uint64_t)s->vram_size_mb * MiB;
    if (vram_bar_size < GPU_VRAM_BAR_MIN) {
        vram_bar_size = GPU_VRAM_BAR_MIN;
    }

    /* Round up to power of 2 for PCI BAR alignment */
    vram_bar_size = 1ULL << (64 - __builtin_clzll(vram_bar_size - 1));

    memory_region_init_ram(&s->vram_bar, OBJECT(s),
                           "emulated-nvidia-gpu-vram",
                           vram_bar_size, errp);
    if (*errp) {
        return;
    }
    pci_register_bar(pci_dev, 1,
                     PCI_BASE_ADDRESS_SPACE_MEMORY |
                     PCI_BASE_ADDRESS_MEM_TYPE_64 |
                     PCI_BASE_ADDRESS_MEM_PREFETCH,
                     &s->vram_bar);

    /* MSI support */
    if (msi_init(pci_dev, 0x50, 1, true, false, errp) < 0) {
        error_report("emulated-nvidia-gpu: MSI init failed, continuing without MSI");
    }

    /* Initialize state */
    s->intr_status = 0;
    s->intr_enable = 0;
    s->engine_enable = 0xFFFFFFFF; /* All engines enabled by default */
    s->boot_id = (s->gpu_device_id << 4) | 0xA1;
    s->timer_base_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    qemu_log("emulated-nvidia-gpu: Initialized as %s "
             "(vendor=0x%04X device=0x%04X subsys=0x%04X vram=%uMB)\n",
             s->gpu_name ? s->gpu_name : "NVIDIA GPU",
             NVIDIA_VENDOR_ID, s->gpu_device_id,
             s->gpu_subsystem_id, s->vram_size_mb);
}

static void emulated_nvidia_gpu_exit(PCIDevice *pci_dev)
{
    msi_uninit(pci_dev);
}

static void emulated_nvidia_gpu_reset(DeviceState *dev)
{
    EmulatedNvidiaGPUState *s = EMULATED_NVIDIA_GPU(dev);

    s->intr_status = 0;
    s->intr_enable = 0;
    s->engine_enable = 0xFFFFFFFF;
    s->timer_base_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
}

/* ════════════════════════════════════════════════════════════════
 *  VM state (migration support)
 * ════════════════════════════════════════════════════════════════ */
static const VMStateDescription vmstate_emulated_nvidia_gpu = {
    .name = "emulated-nvidia-gpu",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_PCI_DEVICE(parent_obj, EmulatedNvidiaGPUState),
        VMSTATE_UINT32(intr_status, EmulatedNvidiaGPUState),
        VMSTATE_UINT32(intr_enable, EmulatedNvidiaGPUState),
        VMSTATE_UINT32(engine_enable, EmulatedNvidiaGPUState),
        VMSTATE_END_OF_LIST()
    }
};

/* ════════════════════════════════════════════════════════════════
 *  Properties
 * ════════════════════════════════════════════════════════════════ */
static Property emulated_nvidia_gpu_properties[] = {
    DEFINE_PROP_UINT32("gpu_device_id", EmulatedNvidiaGPUState,
                       gpu_device_id, DEFAULT_GPU_DEVICE_ID),
    DEFINE_PROP_UINT32("gpu_subsystem_id", EmulatedNvidiaGPUState,
                       gpu_subsystem_id, DEFAULT_SUBSYSTEM_ID),
    DEFINE_PROP_UINT32("vram_size_mb", EmulatedNvidiaGPUState,
                       vram_size_mb, DEFAULT_VRAM_SIZE_MB),
    DEFINE_PROP_STRING("gpu_name", EmulatedNvidiaGPUState,
                       gpu_name),
    DEFINE_PROP_END_OF_LIST(),
};

/* ════════════════════════════════════════════════════════════════
 *  Class and type registration
 * ════════════════════════════════════════════════════════════════ */
static void emulated_nvidia_gpu_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *pc = PCI_DEVICE_CLASS(klass);

    pc->realize = emulated_nvidia_gpu_realize;
    pc->exit = emulated_nvidia_gpu_exit;
    pc->vendor_id = NVIDIA_VENDOR_ID;
    pc->device_id = DEFAULT_GPU_DEVICE_ID;
    pc->class_id = PCI_CLASS_DISPLAY_VGA;
    pc->revision = 0xA1;

    dc->desc = "Emulated NVIDIA GPU (PCI identity only, no rendering)";
    dc->reset = emulated_nvidia_gpu_reset;
    dc->vmsd = &vmstate_emulated_nvidia_gpu;
    device_class_set_props(dc, emulated_nvidia_gpu_properties);

    set_bit(DEVICE_CATEGORY_DISPLAY, dc->categories);
}

static const TypeInfo emulated_nvidia_gpu_info = {
    .name          = TYPE_EMULATED_NVIDIA_GPU,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(EmulatedNvidiaGPUState),
    .class_init    = emulated_nvidia_gpu_class_init,
    .interfaces    = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    },
};

static void emulated_nvidia_gpu_register_types(void)
{
    type_register_static(&emulated_nvidia_gpu_info);
}

type_init(emulated_nvidia_gpu_register_types)
