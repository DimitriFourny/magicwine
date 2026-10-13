/* SPDX-License-Identifier: GPL-3.0-or-later
 * Runs against the real MagicWine DLLs under Wine, not a mocked XInput API.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned failures;
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); ++failures; } } while (0)
static uint8_t *shared;
static uint64_t now_ms(void)
{
    FILETIME ft;
    ULARGE_INTEGER value;
    GetSystemTimeAsFileTime(&ft);
    value.LowPart = ft.dwLowDateTime;
    value.HighPart = ft.dwHighDateTime;
    return (value.QuadPart - UINT64_C(116444736000000000)) / 10000;
}
static void u16(unsigned offset, uint16_t value) { memcpy(shared + offset, &value, sizeof(value)); }
static void u32(unsigned offset, uint32_t value) { memcpy(shared + offset, &value, sizeof(value)); }
static void u64(unsigned offset, uint64_t value) { memcpy(shared + offset, &value, sizeof(value)); }
static uint16_t read16(unsigned offset) { uint16_t value; memcpy(&value, shared + offset, 2); return value; }
static void state(unsigned packet, unsigned buttons, int connected)
{
    InterlockedIncrement((volatile LONG *)(shared + 8));
    u64(16, now_ms());
    u32(32, connected);
    u32(36, packet);
    u16(40, buttons);
    shared[42] = 64;
    shared[43] = 192;
    u16(44, (uint16_t)-16384);
    u16(46, 32767);
    u16(48, 8192);
    u16(50, (uint16_t)-32768);
    shared[52] = BATTERY_LEVEL_FULL;
    shared[53] = BATTERY_TYPE_ALKALINE;
    shared[54] = 1;
    MemoryBarrier();
    InterlockedIncrement((volatile LONG *)(shared + 8));
}

typedef DWORD (WINAPI *get_state_fn)(DWORD, XINPUT_STATE *);
typedef DWORD (WINAPI *get_caps_fn)(DWORD, DWORD, XINPUT_CAPABILITIES *);
typedef DWORD (WINAPI *set_state_fn)(DWORD, XINPUT_VIBRATION *);
typedef void (WINAPI *enable_fn)(BOOL);
typedef DWORD (WINAPI *get_battery_fn)(DWORD, BYTE, XINPUT_BATTERY_INFORMATION *);
typedef DWORD (WINAPI *get_key_fn)(DWORD, DWORD, XINPUT_KEYSTROKE *);

static void exercise(const char *name)
{
    HMODULE dll = LoadLibraryA(name);
    XINPUT_STATE input;
    XINPUT_CAPABILITIES caps;
    XINPUT_BATTERY_INFORMATION battery;
    XINPUT_VIBRATION vibration = {16384, 49152};
    XINPUT_KEYSTROKE key;
    CHECK(dll != NULL);
    if (!dll) return;
    get_state_fn get_state = (get_state_fn)(void *)GetProcAddress(dll, "XInputGetState");
    get_state_fn get_extended = (get_state_fn)(void *)GetProcAddress(dll, (LPCSTR)100);
    get_caps_fn get_caps = (get_caps_fn)(void *)GetProcAddress(dll, "XInputGetCapabilities");
    set_state_fn set_state = (set_state_fn)(void *)GetProcAddress(dll, "XInputSetState");
    enable_fn enable = (enable_fn)(void *)GetProcAddress(dll, "XInputEnable");
    get_battery_fn get_battery = (get_battery_fn)(void *)GetProcAddress(dll, "XInputGetBatteryInformation");
    get_key_fn get_key = (get_key_fn)(void *)GetProcAddress(dll, "XInputGetKeystroke");
    CHECK(get_state && get_extended && get_caps && set_state && enable && get_battery && get_key);
    if (!get_state || !get_extended || !get_caps || !set_state || !enable || !get_battery || !get_key) {
        FreeLibrary(dll);
        return;
    }
    state(1, XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_DPAD_LEFT | 0x0400, 1);
    CHECK(get_state(0, &input) == ERROR_SUCCESS);
    CHECK(input.dwPacketNumber == 1);
    CHECK(input.Gamepad.wButtons == (XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_DPAD_LEFT));
    CHECK(input.Gamepad.bLeftTrigger == 64 && input.Gamepad.bRightTrigger == 192);
    CHECK(input.Gamepad.sThumbLX == -16384 && input.Gamepad.sThumbLY == 32767);
    CHECK(input.Gamepad.sThumbRX == 8192 && input.Gamepad.sThumbRY == -32768);
    CHECK(get_extended(0, &input) == ERROR_SUCCESS && (input.Gamepad.wButtons & 0x0400));
    CHECK(get_state(1, &input) == ERROR_DEVICE_NOT_CONNECTED);
    CHECK(get_state(4, &input) != ERROR_SUCCESS);
    CHECK(get_state(0, NULL) != ERROR_SUCCESS);
    CHECK(get_caps(0, XINPUT_FLAG_GAMEPAD, &caps) == ERROR_SUCCESS);
    CHECK(caps.Type == XINPUT_DEVTYPE_GAMEPAD && caps.SubType == XINPUT_DEVSUBTYPE_GAMEPAD);
    CHECK(get_battery(0, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_SUCCESS);
    CHECK(battery.BatteryType == BATTERY_TYPE_ALKALINE && battery.BatteryLevel == BATTERY_LEVEL_FULL);
    CHECK(set_state(0, &vibration) == ERROR_SUCCESS);
    CHECK(read16(292) == 16384 && read16(294) == 49152);
    if (!strcmp(name, "xinput1_1.dll")) {
        /* A single SetState must keep vibrating without GetState polling.
         * Refresh only the host heartbeat while the DLL renews its own lease. */
        uint32_t generation;
        memcpy(&generation, shared + 288, sizeof(generation));
        for (unsigned i = 0; i < 3; ++i) {
            Sleep(750);
            state(1, XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_DPAD_LEFT | 0x0400, 1);
        }
        uint32_t renewed;
        memcpy(&renewed, shared + 288, sizeof(renewed));
        CHECK(renewed != generation && !(renewed & 1));
        CHECK(read16(292) == 16384 && read16(294) == 49152);
        /* A newer client owns this slot; the old timer must not resurrect its
         * previous motor speeds over that client's request. */
        InterlockedIncrement((volatile LONG *)(shared + 288));
        u16(292, 800);
        u16(294, 0);
        u64(296, now_ms());
        InterlockedIncrement((volatile LONG *)(shared + 288));
        Sleep(750);
        state(1, XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_DPAD_LEFT | 0x0400, 1);
        CHECK(read16(292) == 800 && read16(294) == 0);
        CHECK(set_state(0, &vibration) == ERROR_SUCCESS);
    }
    enable(FALSE);
    CHECK(get_state(0, &input) == ERROR_SUCCESS);
    CHECK(input.Gamepad.wButtons == 0 && input.Gamepad.bLeftTrigger == 0 && input.Gamepad.sThumbLX == 0);
    CHECK(read16(292) == 0 && read16(294) == 0);
    enable(TRUE);
    CHECK(get_state(0, &input) == ERROR_SUCCESS && (input.Gamepad.wButtons & XINPUT_GAMEPAD_A));

    /* Drain existing keys; then verify a new face-button press and release. */
    state(2, 0, 1);
    for (unsigned i = 0; i < 32 && get_key(0, 0, &key) == ERROR_SUCCESS; ++i) {}
    state(3, XINPUT_GAMEPAD_B, 1);
    CHECK(get_key(0, 0, &key) == ERROR_SUCCESS);
    CHECK(key.VirtualKey == VK_PAD_B && (key.Flags & XINPUT_KEYSTROKE_KEYDOWN));
    state(4, 0, 1);
    CHECK(get_key(0, 0, &key) == ERROR_SUCCESS);
    CHECK(key.VirtualKey == VK_PAD_B && (key.Flags & XINPUT_KEYSTROKE_KEYUP));

    state(5, XINPUT_GAMEPAD_A, 0);
    CHECK(get_state(0, &input) == ERROR_DEVICE_NOT_CONNECTED);
    state(6, XINPUT_GAMEPAD_A, 1);
    CHECK(get_state(0, &input) == ERROR_SUCCESS && input.dwPacketNumber == 6);
    u64(16, now_ms() - 3000);
    CHECK(get_state(0, &input) == ERROR_DEVICE_NOT_CONNECTED);
    state(7, XINPUT_GAMEPAD_X, 1);
    u32(4, 99);
    CHECK(get_state(0, &input) == ERROR_DEVICE_NOT_CONNECTED);
    u32(4, 1);
    InterlockedIncrement((volatile LONG *)(shared + 8));
    CHECK(get_state(0, &input) == ERROR_DEVICE_NOT_CONNECTED);
    InterlockedIncrement((volatile LONG *)(shared + 8));
    CHECK(get_state(0, &input) == ERROR_SUCCESS && input.Gamepad.wButtons == XINPUT_GAMEPAD_X);
    printf("%s: state, bounds, capabilities, battery, rumble, enable, keys, disconnect, heartbeat, seqlock checked\n", name);
    FreeLibrary(dll);
}

int main(void)
{
    WCHAR directory[MAX_PATH], path[MAX_PATH];
    CHECK(GetTempPathW(MAX_PATH, directory) != 0);
    CHECK(GetTempFileNameW(directory, L"mwg", 0, path) != 0);
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, NULL);
    CHECK(file != INVALID_HANDLE_VALUE);
    if (file == INVALID_HANDLE_VALUE) return 1;
    SetFilePointer(file, 512, NULL, FILE_BEGIN);
    CHECK(SetEndOfFile(file));
    HANDLE mapping = CreateFileMappingW(file, NULL, PAGE_READWRITE, 0, 512, NULL);
    CHECK(mapping != NULL);
    shared = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 512);
    CHECK(shared != NULL);
    if (!shared) return 1;
    memset(shared, 0, 512);
    u32(0, 0x4D574750);
    u32(4, 1);
    CHECK(SetEnvironmentVariableW(L"MAGICWINE_GAMEPAD_STATE", path));
    const char *names[] = {"xinput1_1.dll", "xinput1_2.dll", "xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll"};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) exercise(names[i]);
    UnmapViewOfFile(shared);
    CloseHandle(mapping);
    CloseHandle(file);
    DeleteFileW(path);
    printf("XInput bridge: %u failures (%u-bit)\n", failures, (unsigned)(8 * sizeof(void *)));
    return failures ? 1 : 0;
}
