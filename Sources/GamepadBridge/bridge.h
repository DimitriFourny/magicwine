/* SPDX-License-Identifier: GPL-3.0-or-later
 * MagicWine shared-file ABI v1. All fields are little-endian. macOS hosts are
 * arm64/x86_64 and Windows guests are i686/x86_64. Sequences are aligned atomic
 * 32-bit words; the 64-bit timestamps are accessed only inside their seqlocks.
 */
#ifndef MAGICWINE_GAMEPAD_BRIDGE_H
#define MAGICWINE_GAMEPAD_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#define MW_MAGIC UINT32_C(0x4d574750)
#define MW_VERSION 1
#define MW_FILE_SIZE 512
#define MW_SLOTS 4
#define MW_TIMEOUT_MS 2000
#define MW_RUMBLE_OFFSET 288
#define MW_RUMBLE_STRIDE 16

struct mw_slot {
    uint32_t connected, packet;
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t left_x, left_y, right_x, right_y;
    uint8_t battery_level, battery_type, supports_vibration;
    uint8_t reserved[41];
};
struct mw_state {
    uint32_t magic, version, sequence, reserved;
    uint64_t heartbeat;
    uint8_t padding[8];
    struct mw_slot slots[MW_SLOTS];
};
struct mw_vibration {
    uint32_t sequence;
    uint16_t left, right;
    uint64_t written;
};
_Static_assert(sizeof(struct mw_slot) == 64, "slot ABI");
_Static_assert(offsetof(struct mw_slot, buttons) == 8, "buttons ABI");
_Static_assert(offsetof(struct mw_slot, battery_level) == 20, "battery ABI");
_Static_assert(offsetof(struct mw_state, heartbeat) == 16, "heartbeat ABI");
_Static_assert(offsetof(struct mw_state, slots) == 32, "slots ABI");
_Static_assert(sizeof(struct mw_state) == MW_RUMBLE_OFFSET, "state ABI");
_Static_assert(sizeof(struct mw_vibration) == MW_RUMBLE_STRIDE, "vibration ABI");
_Static_assert(offsetof(struct mw_vibration, written) == 8, "vibration timestamp ABI");
#endif
