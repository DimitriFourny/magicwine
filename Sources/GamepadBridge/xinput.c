/* SPDX-License-Identifier: MIT
 * Original MagicWine XInput bridge. The shared-file ABI is declared in bridge.h.
 * No controller enumeration or synthetic fallback takes place inside Wine.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <string.h>
#include "bridge.h"

/* All per-DLL state, including mapping lifetime and keystroke consumption, is
 * serialized. Shared rumble writes additionally arbitrate across DLL instances
 * and processes with the naturally aligned, interlocked sequence word. */
static SRWLOCK lock = SRWLOCK_INIT;
static HANDLE state_file = INVALID_HANDLE_VALUE, state_mapping;
static volatile unsigned char *shared;
static WCHAR state_path[32768];
static ULONGLONG next_open;
static BOOL enabled = TRUE;
static XINPUT_VIBRATION desired[MW_SLOTS];
static uint32_t rumble_generation[MW_SLOTS];
static BOOL rumble_owned[MW_SLOTS];
static PTP_TIMER rumble_timer;
static HMODULE timer_module;

/* Keystrokes are generated from the last delivered key state, with one event
 * consumed per call. Simultaneous changes therefore are not dropped. */
#define KEY_COUNT 32
static uint32_t keys_delivered[MW_SLOTS];
static ULONGLONG repeat_due[MW_SLOTS][KEY_COUNT];
static const WORD virtual_keys[KEY_COUNT] = {
    VK_PAD_A, VK_PAD_B, VK_PAD_X, VK_PAD_Y,
    VK_PAD_RSHOULDER, VK_PAD_LSHOULDER, VK_PAD_LTRIGGER, VK_PAD_RTRIGGER,
    VK_PAD_DPAD_UP, VK_PAD_DPAD_DOWN, VK_PAD_DPAD_LEFT, VK_PAD_DPAD_RIGHT,
    VK_PAD_START, VK_PAD_BACK, VK_PAD_LTHUMB_PRESS, VK_PAD_RTHUMB_PRESS,
    VK_PAD_LTHUMB_UP, VK_PAD_LTHUMB_DOWN, VK_PAD_LTHUMB_RIGHT, VK_PAD_LTHUMB_LEFT,
    VK_PAD_LTHUMB_UPLEFT, VK_PAD_LTHUMB_UPRIGHT, VK_PAD_LTHUMB_DOWNRIGHT, VK_PAD_LTHUMB_DOWNLEFT,
    VK_PAD_RTHUMB_UP, VK_PAD_RTHUMB_DOWN, VK_PAD_RTHUMB_RIGHT, VK_PAD_RTHUMB_LEFT,
    VK_PAD_RTHUMB_UPLEFT, VK_PAD_RTHUMB_UPRIGHT, VK_PAD_RTHUMB_DOWNRIGHT, VK_PAD_RTHUMB_DOWNLEFT
};

static uint64_t unix_ms(void)
{
    FILETIME ft;
    ULARGE_INTEGER value;
    GetSystemTimeAsFileTime(&ft);
    value.LowPart = ft.dwLowDateTime;
    value.HighPart = ft.dwHighDateTime;
    return value.QuadPart / 10000 - UINT64_C(11644473600000);
}

static void close_mapping(void)
{
    if (shared) UnmapViewOfFile((const void *)shared);
    if (state_mapping) CloseHandle(state_mapping);
    if (state_file != INVALID_HANDLE_VALUE) CloseHandle(state_file);
    shared = NULL;
    state_mapping = NULL;
    state_file = INVALID_HANDLE_VALUE;
}

static BOOL open_mapping(void)
{
    DWORD length;
    LARGE_INTEGER size;
    ULONGLONG now;
    if (shared) return TRUE;
    now = GetTickCount64();
    if (now < next_open) return FALSE;
    next_open = now + 250;
    length = GetEnvironmentVariableW(L"MAGICWINE_GAMEPAD_STATE", state_path,
                                    (DWORD)(sizeof(state_path) / sizeof(state_path[0])));
    if (!length || length >= sizeof(state_path) / sizeof(state_path[0])) return FALSE;
    state_file = CreateFileW(state_path, GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (state_file == INVALID_HANDLE_VALUE) return FALSE;
    if (!GetFileSizeEx(state_file, &size) || size.QuadPart != MW_FILE_SIZE) goto fail;
    state_mapping = CreateFileMappingW(state_file, NULL, PAGE_READWRITE, 0, MW_FILE_SIZE, NULL);
    if (!state_mapping) goto fail;
    shared = MapViewOfFile(state_mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, MW_FILE_SIZE);
    if (shared) return TRUE;
fail:
    close_mapping();
    return FALSE;
}

static DWORD snapshot(struct mw_state *out)
{
    unsigned int attempt, index;
    LONG before, after;
    uint64_t now;
    volatile LONG *sequence;
    unsigned char *bytes = (unsigned char *)out;
    if (!open_mapping()) return ERROR_DEVICE_NOT_CONNECTED;
    sequence = (volatile LONG *)(shared + 8);
    for (attempt = 0; attempt < 32; ++attempt) {
        before = InterlockedCompareExchange(sequence, 0, 0);
        if (before & 1) { YieldProcessor(); continue; }
        for (index = 0; index < sizeof(*out); ++index) bytes[index] = shared[index];
        MemoryBarrier();
        after = InterlockedCompareExchange(sequence, 0, 0);
        if (before != after || (after & 1)) continue;
        if (out->magic != MW_MAGIC || out->version != MW_VERSION) return ERROR_DEVICE_NOT_CONNECTED;
        now = unix_ms();
        if (!out->heartbeat || (now >= out->heartbeat ? now - out->heartbeat : out->heartbeat - now) > MW_TIMEOUT_MS)
            return ERROR_DEVICE_NOT_CONNECTED;
        return ERROR_SUCCESS;
    }
    return ERROR_BUSY;
}

static DWORD get_slot(DWORD index, struct mw_slot *slot)
{
    struct mw_state state;
    DWORD result;
    if (index >= MW_SLOTS) return ERROR_DEVICE_NOT_CONNECTED;
    result = snapshot(&state);
    if (result != ERROR_SUCCESS || state.slots[index].connected != 1) {
        keys_delivered[index] = 0;
        memset(repeat_due[index], 0, sizeof(repeat_due[index]));
        if (result != ERROR_BUSY) {
            memset(&desired[index], 0, sizeof(desired[index]));
            rumble_owned[index] = FALSE;
        }
        return ERROR_DEVICE_NOT_CONNECTED;
    }
    *slot = state.slots[index];
    return ERROR_SUCCESS;
}

static XINPUT_GAMEPAD gamepad(const struct mw_slot *slot)
{
    XINPUT_GAMEPAD pad;
    memset(&pad, 0, sizeof(pad));
    if (enabled) {
        pad.wButtons = slot->buttons & 0xf7ff;
        pad.bLeftTrigger = slot->left_trigger;
        pad.bRightTrigger = slot->right_trigger;
        pad.sThumbLX = slot->left_x;
        pad.sThumbLY = slot->left_y;
        pad.sThumbRX = slot->right_x;
        pad.sThumbRY = slot->right_y;
    }
    return pad;
}

static DWORD get_state(DWORD index, XINPUT_STATE *state, BOOL extended)
{
    struct mw_slot slot;
    DWORD result;
    if (!state) return ERROR_BAD_ARGUMENTS;
    memset(state, 0, sizeof(*state));
    AcquireSRWLockExclusive(&lock);
    result = get_slot(index, &slot);
    if (result == ERROR_SUCCESS) {
        state->dwPacketNumber = slot.packet;
        state->Gamepad = gamepad(&slot);
        if (!extended) state->Gamepad.wButtons &= ~0x0400;
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
}

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state) { return get_state(index, state, FALSE); }
DWORD WINAPI XInputGetStateEx(DWORD index, XINPUT_STATE *state) { return get_state(index, state, TRUE); }

static DWORD write_vibration(DWORD index, const XINPUT_VIBRATION *vibration, BOOL only_owned)
{
    volatile struct mw_vibration *request;
    volatile LONG *sequence;
    unsigned int attempt;
    LONG before;
    if (!shared) return ERROR_DEVICE_NOT_CONNECTED;
    request = (volatile struct mw_vibration *)(shared + MW_RUMBLE_OFFSET + index * MW_RUMBLE_STRIDE);
    sequence = (volatile LONG *)&request->sequence;
    for (attempt = 0; attempt < 64; ++attempt) {
        before = InterlockedCompareExchange(sequence, 0, 0);
        if (!(before & 1) && only_owned &&
            (!rumble_owned[index] || (uint32_t)before != rumble_generation[index]))
            return ERROR_CANCELLED;
        if ((before & 1) || InterlockedCompareExchange(sequence, (LONG)((uint32_t)before + 1), before) != before) {
            YieldProcessor();
            continue;
        }
        request->left = vibration->wLeftMotorSpeed;
        request->right = vibration->wRightMotorSpeed;
        request->written = unix_ms();
        MemoryBarrier();
        InterlockedExchange(sequence, (LONG)((uint32_t)before + 2));
        rumble_generation[index] = (uint32_t)before + 2;
        rumble_owned[index] = TRUE;
        return ERROR_SUCCESS;
    }
    return ERROR_BUSY;
}

static VOID CALLBACK maintain_vibration(PTP_CALLBACK_INSTANCE instance, PVOID context, PTP_TIMER fired)
{
    unsigned int index;
    BOOL active = FALSE;
    HMODULE release = NULL;
    struct mw_slot slot;
    DWORD result;
    (void)context;
    AcquireSRWLockExclusive(&lock);
    for (index = 0; index < MW_SLOTS; ++index) {
        if (!enabled || !rumble_owned[index] ||
            (!desired[index].wLeftMotorSpeed && !desired[index].wRightMotorSpeed)) continue;
        if (get_slot(index, &slot) != ERROR_SUCCESS) {
            /* A publisher briefly holding its seqlock is not a lost lease. */
            if (rumble_owned[index]) active = TRUE;
            continue;
        }
        if (!slot.supports_vibration) {
            rumble_owned[index] = FALSE;
            continue;
        }
        result = write_vibration(index, &desired[index], TRUE);
        if (result == ERROR_CANCELLED) {
            /* A newer SetState in another DLL/process owns this slot now. */
            rumble_owned[index] = FALSE;
            memset(&desired[index], 0, sizeof(desired[index]));
        } else if (result == ERROR_SUCCESS || result == ERROR_BUSY) active = TRUE;
    }
    if (!active) {
        SetThreadpoolTimer(fired, NULL, 0, 0);
        CloseThreadpoolTimer(fired);
        rumble_timer = NULL;
        release = timer_module;
        timer_module = NULL;
    } else {
        FILETIME due = {(DWORD)-5000000, 0xffffffff};
        /* Rearm a one-shot instead of queuing overlapping periodic callbacks. */
        SetThreadpoolTimer(fired, &due, 0, 0);
    }
    ReleaseSRWLockExclusive(&lock);
    /* Holding a module reference while callbacks can run avoids an unload race,
     * without ever waiting for worker threads from inside DllMain. */
    if (release) FreeLibraryWhenCallbackReturns(instance, release);
}

static BOOL ensure_rumble_timer(void)
{
    FILETIME due = {(DWORD)-5000000, 0xffffffff};
    if (rumble_timer) return TRUE;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)(ULONG_PTR)&maintain_vibration, &timer_module)) return FALSE;
    rumble_timer = CreateThreadpoolTimer(maintain_vibration, NULL, NULL);
    if (!rumble_timer) {
        FreeLibrary(timer_module);
        timer_module = NULL;
        return FALSE;
    }
    SetThreadpoolTimer(rumble_timer, &due, 0, 0);
    return TRUE;
}

DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration)
{
    struct mw_slot slot;
    DWORD result;
    BOOL nonzero;
    if (!vibration) return ERROR_BAD_ARGUMENTS;
    AcquireSRWLockExclusive(&lock);
    result = get_slot(index, &slot);
    if (result == ERROR_SUCCESS) {
        if (!slot.supports_vibration) result = ERROR_NOT_SUPPORTED;
        else if (!enabled) desired[index] = *vibration;
        else {
            nonzero = vibration->wLeftMotorSpeed || vibration->wRightMotorSpeed;
            if (nonzero && !ensure_rumble_timer()) result = ERROR_NOT_ENOUGH_MEMORY;
            else {
                result = write_vibration(index, vibration, FALSE);
                if (result == ERROR_SUCCESS) desired[index] = *vibration;
            }
        }
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
}

void WINAPI XInputEnable(BOOL enable)
{
    unsigned int index;
    const XINPUT_VIBRATION stopped = {0, 0};
    struct mw_slot slot;
    AcquireSRWLockExclusive(&lock);
    if (enabled != !!enable) {
        enabled = !!enable;
        for (index = 0; index < MW_SLOTS; ++index) {
            if (get_slot(index, &slot) != ERROR_SUCCESS || !slot.supports_vibration) continue;
            if (!enabled) {
                if (rumble_owned[index]) write_vibration(index, &stopped, TRUE);
            } else if (desired[index].wLeftMotorSpeed || desired[index].wRightMotorSpeed) {
                if (ensure_rumble_timer()) write_vibration(index, &desired[index], FALSE);
            }
        }
    }
    ReleaseSRWLockExclusive(&lock);
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *capabilities)
{
    struct mw_slot slot;
    DWORD result;
    if (!capabilities || (flags & ~XINPUT_FLAG_GAMEPAD)) return ERROR_BAD_ARGUMENTS;
    memset(capabilities, 0, sizeof(*capabilities));
    AcquireSRWLockExclusive(&lock);
    result = get_slot(index, &slot);
    if (result == ERROR_SUCCESS) {
        capabilities->Type = XINPUT_DEVTYPE_GAMEPAD;
        capabilities->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
        capabilities->Gamepad.wButtons = 0xf3ff;
        capabilities->Gamepad.bLeftTrigger = capabilities->Gamepad.bRightTrigger = 255;
        capabilities->Gamepad.sThumbLX = capabilities->Gamepad.sThumbLY = 32767;
        capabilities->Gamepad.sThumbRX = capabilities->Gamepad.sThumbRY = 32767;
        if (slot.supports_vibration) {
            capabilities->Flags = XINPUT_CAPS_FFB_SUPPORTED;
            capabilities->Vibration.wLeftMotorSpeed = capabilities->Vibration.wRightMotorSpeed = 65535;
        }
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
}

DWORD WINAPI XInputGetBatteryInformation(DWORD index, BYTE type, XINPUT_BATTERY_INFORMATION *battery)
{
    struct mw_slot slot;
    DWORD result;
    if (!battery || type > BATTERY_DEVTYPE_HEADSET) return ERROR_BAD_ARGUMENTS;
    memset(battery, 0, sizeof(*battery));
    AcquireSRWLockExclusive(&lock);
    result = get_slot(index, &slot);
    if (result == ERROR_SUCCESS) {
        if (type == BATTERY_DEVTYPE_HEADSET) result = ERROR_NOT_SUPPORTED;
        else {
            battery->BatteryType = slot.battery_type;
            battery->BatteryLevel = slot.battery_level <= 3 ? slot.battery_level : BATTERY_LEVEL_EMPTY;
        }
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
}

static uint32_t stick_key(SHORT x, SHORT y, int threshold, unsigned int base)
{
    int horizontal = x > threshold ? 1 : (x < -threshold ? -1 : 0);
    int vertical = y > threshold ? 1 : (y < -threshold ? -1 : 0);
    unsigned int direction;
    if (!horizontal && !vertical) return 0;
    if (vertical > 0) direction = horizontal < 0 ? 4 : (horizontal > 0 ? 5 : 0);
    else if (vertical < 0) direction = horizontal < 0 ? 7 : (horizontal > 0 ? 6 : 1);
    else direction = horizontal > 0 ? 2 : 3;
    return UINT32_C(1) << (base + direction);
}

static uint32_t pressed_keys(const struct mw_slot *slot)
{
    static const WORD buttons[16] = {0x1000, 0x2000, 0x4000, 0x8000, 0x0200, 0x0100, 0, 0,
                                    0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080};
    XINPUT_GAMEPAD pad = gamepad(slot);
    uint32_t keys = 0;
    unsigned int index;
    for (index = 0; index < 16; ++index)
        if (pad.wButtons & buttons[index]) keys |= UINT32_C(1) << index;
    if (pad.bLeftTrigger > XINPUT_GAMEPAD_TRIGGER_THRESHOLD) keys |= UINT32_C(1) << 6;
    if (pad.bRightTrigger > XINPUT_GAMEPAD_TRIGGER_THRESHOLD) keys |= UINT32_C(1) << 7;
    return keys | stick_key(pad.sThumbLX, pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, 16) |
                  stick_key(pad.sThumbRX, pad.sThumbRY, XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE, 24);
}

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD reserved, XINPUT_KEYSTROKE *stroke)
{
    DWORD first, end, slot_index, result = ERROR_DEVICE_NOT_CONNECTED;
    unsigned int key;
    uint32_t pressed, changed, bit;
    ULONGLONG now = GetTickCount64();
    struct mw_slot slot;
    if (!stroke || reserved) return ERROR_BAD_ARGUMENTS;
    memset(stroke, 0, sizeof(*stroke));
    if (index >= MW_SLOTS && index != XUSER_INDEX_ANY) return ERROR_DEVICE_NOT_CONNECTED;
    first = index == XUSER_INDEX_ANY ? 0 : index;
    end = index == XUSER_INDEX_ANY ? MW_SLOTS : index + 1;
    AcquireSRWLockExclusive(&lock);
    for (slot_index = first; slot_index < end; ++slot_index) {
        if (get_slot(slot_index, &slot) != ERROR_SUCCESS) continue;
        result = ERROR_EMPTY;
        pressed = pressed_keys(&slot);
        changed = pressed ^ keys_delivered[slot_index];
        /* Drain transitions before auto-repeat. */
        for (key = 0; key < KEY_COUNT; ++key) {
            bit = UINT32_C(1) << key;
            if (!(changed & bit)) continue;
            keys_delivered[slot_index] ^= bit;
            stroke->Flags = pressed & bit ? XINPUT_KEYSTROKE_KEYDOWN : XINPUT_KEYSTROKE_KEYUP;
            repeat_due[slot_index][key] = pressed & bit ? now + 500 : 0;
            goto event;
        }
        for (key = 0; key < KEY_COUNT; ++key) {
            bit = UINT32_C(1) << key;
            if ((pressed & bit) && repeat_due[slot_index][key] && now >= repeat_due[slot_index][key]) {
                stroke->Flags = XINPUT_KEYSTROKE_KEYDOWN | XINPUT_KEYSTROKE_REPEAT;
                repeat_due[slot_index][key] = now + 50;
                goto event;
            }
        }
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
event:
    stroke->VirtualKey = virtual_keys[key];
    stroke->UserIndex = (BYTE)slot_index;
    ReleaseSRWLockExclusive(&lock);
    return ERROR_SUCCESS;
}

static DWORD unsupported(DWORD index)
{
    struct mw_slot slot;
    DWORD result;
    AcquireSRWLockExclusive(&lock);
    result = get_slot(index, &slot);
    ReleaseSRWLockExclusive(&lock);
    return result == ERROR_SUCCESS ? ERROR_NOT_SUPPORTED : result;
}

DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD index, GUID *render, GUID *capture)
{
    if (!render || !capture) return ERROR_BAD_ARGUMENTS;
    memset(render, 0, sizeof(*render));
    memset(capture, 0, sizeof(*capture));
    return unsupported(index);
}

DWORD WINAPI XInputGetAudioDeviceIds(DWORD index, WCHAR *render, UINT *render_count,
                                    WCHAR *capture, UINT *capture_count)
{
    if (!render_count || !capture_count) return ERROR_BAD_ARGUMENTS;
    if (render && *render_count) *render = 0;
    if (capture && *capture_count) *capture = 0;
    *render_count = *capture_count = 0;
    return unsupported(index);
}

/* These undocumented ordinal APIs cannot honestly provide power control,
 * guide-event handles, USB identity or audio devices from GameController. */
DWORD WINAPI XInputWaitForGuideButton(DWORD index, DWORD flags, void *listen)
{
    (void)flags;
    if (!listen) return ERROR_BAD_ARGUMENTS;
    return unsupported(index);
}
DWORD WINAPI XInputCancelGuideButtonWait(DWORD index) { return unsupported(index); }
DWORD WINAPI XInputPowerOffController(DWORD index) { return unsupported(index); }
DWORD WINAPI XInputGetCapabilitiesEx(DWORD reserved, DWORD index, DWORD flags, XINPUT_CAPABILITIES_EX *capabilities)
{
    (void)reserved;
    if (!capabilities || (flags & ~XINPUT_FLAG_GAMEPAD)) return ERROR_BAD_ARGUMENTS;
    memset(capabilities, 0, sizeof(*capabilities));
    return unsupported(index);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    /* No waits, mapping creation or controller calls under the loader lock.
     * Timer callbacks hold a module reference until inactive. Process teardown
     * abandons the final lease; the host stops it within two seconds. */
    if (reason == DLL_PROCESS_DETACH) close_mapping();
    return TRUE;
}
