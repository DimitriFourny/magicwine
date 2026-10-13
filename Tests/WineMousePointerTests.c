/* Mouse-in-pointer behavior against a real Wine runtime, in both Windows ABIs.
 * Run with scripts/test-mouse-pointer.sh; no desktop-wide automation permissions.
 */
#define WINVER 0x0602
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <windowsx.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned failures, pointer_count, classic_count, raw_count;
static BOOL enabled;
static HWND window;
static UINT expected_message;
static POINTER_FLAGS expected_buttons;
static POINTER_BUTTON_CHANGE_TYPE expected_change;
static int expected_wheel;

#define check(condition, ...) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; \
} } while (0)

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) classic_count++;
    if (message == WM_INPUT)
    {
        RAWINPUT input = {0};
        UINT size = sizeof(input);
        check(GetRawInputData((HRAWINPUT)lparam, RID_INPUT, &input, &size, sizeof(RAWINPUTHEADER)) != (UINT)-1,
              "raw mouse data could not be read");
        check(input.header.dwType == RIM_TYPEMOUSE, "unexpected raw input device");
        raw_count++;
    }
    if (message == WM_POINTERDOWN || message == WM_POINTERUPDATE || message == WM_POINTERUP ||
        message == WM_POINTERWHEEL || message == WM_POINTERHWHEEL)
    {
        POINTER_INFO info;
        POINTER_INPUT_TYPE type;
        UINT id = GET_POINTERID_WPARAM(wparam);
        const POINTER_FLAGS buttons = POINTER_FLAG_FIRSTBUTTON | POINTER_FLAG_SECONDBUTTON |
            POINTER_FLAG_THIRDBUTTON | POINTER_FLAG_FOURTHBUTTON | POINTER_FLAG_FIFTHBUTTON;
        pointer_count++;
        check(enabled, "disabled process received pointer input");
        check(message == expected_message, "message %#x, expected %#x", message, expected_message);
        check(GetPointerType(id, &type) && type == PT_MOUSE, "pointer %u is not a mouse", id);
        if (!GetPointerInfo(id, &info))
        {
            check(FALSE, "GetPointerInfo(%u) failed: %lu", id, GetLastError());
            return 0;
        }
        check(info.pointerType == PT_MOUSE && info.pointerId == id, "incorrect mouse identity");
        check(info.hwndTarget == hwnd, "wrong target window");
        check(info.ptPixelLocation.x == GET_X_LPARAM(lparam) &&
              info.ptPixelLocation.y == GET_Y_LPARAM(lparam), "screen coordinates disagree");
        check((info.pointerFlags & buttons) == expected_buttons,
              "button flags %#x, expected %#x", (unsigned)(info.pointerFlags & buttons), (unsigned)expected_buttons);
        check(!!(info.pointerFlags & POINTER_FLAG_INCONTACT) == !!expected_buttons,
              "contact state %#x disagrees with held buttons %#x", (unsigned)info.pointerFlags, (unsigned)expected_buttons);
        check(info.ButtonChangeType == expected_change, "button transition %u, expected %u",
              info.ButtonChangeType, expected_change);
        if (message == WM_POINTERWHEEL || message == WM_POINTERHWHEEL)
            check(GET_WHEEL_DELTA_WPARAM(wparam) == expected_wheel, "wheel delta %d, expected %d",
                  GET_WHEEL_DELTA_WPARAM(wparam), expected_wheel);
        else
        {
            const WORD message_buttons = POINTER_MESSAGE_FLAG_FIRSTBUTTON | POINTER_MESSAGE_FLAG_SECONDBUTTON |
                POINTER_MESSAGE_FLAG_THIRDBUTTON | POINTER_MESSAGE_FLAG_FOURTHBUTTON | POINTER_MESSAGE_FLAG_FIFTHBUTTON;
            check((HIWORD(wparam) & message_buttons) == expected_buttons, "message button flags disagree");
            check(!!(HIWORD(wparam) & POINTER_MESSAGE_FLAG_INCONTACT) == !!expected_buttons,
                  "message contact state disagrees");
        }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void pump(DWORD milliseconds)
{
    MSG message;
    DWORD end = GetTickCount() + milliseconds;
    do
    {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Sleep(1);
    } while ((LONG)(GetTickCount() - end) < 0);
}

static void inject(DWORD flags, DWORD data, UINT message, POINTER_FLAGS buttons,
                   POINTER_BUTTON_CHANGE_TYPE change, int wheel)
{
    INPUT input = {0};
    unsigned before = pointer_count, old_classic = classic_count, old_raw = raw_count;
    expected_message = message;
    expected_buttons = buttons;
    expected_change = change;
    expected_wheel = wheel;
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = flags;
    input.mi.mouseData = data;
    if (flags & MOUSEEVENTF_MOVE) { input.mi.dx = 3; input.mi.dy = 2; }
    check(SendInput(1, &input, sizeof(input)) == 1, "SendInput failed: %lu", GetLastError());
    pump(50);
    check(pointer_count == before + !!enabled, "event %#lx produced %u pointer messages, expected %u",
          flags, pointer_count - before, !!enabled);
    check(classic_count == old_classic + 1, "legacy mouse event duplicated or lost for %#lx", flags);
    check(raw_count == old_raw + 1, "raw mouse event duplicated or lost for %#lx", flags);
}

static DWORD WINAPI check_other_thread(void *unused)
{
    POINTER_INFO info;
    (void)unused;
    check(IsMouseInPointerEnabled() == enabled, "enable state is not process-wide");
    check(!GetPointerInfo(1, &info), "another thread exposed the input owner's pointer frame");
    return 0;
}

int main(int argc, char **argv)
{
    WNDCLASSW klass = {0};
    POINTER_INFO info;
    RAWINPUTDEVICE raw = {1, 2, 0, NULL};
    POINT point = {120, 120};
    MSG message;
    INPUT input = {0};
    HANDLE thread;
    unsigned before, i;
    struct button {
        DWORD down, up, data;
        POINTER_FLAGS flag;
        POINTER_BUTTON_CHANGE_TYPE press, release;
    } buttons[] = {
        {MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, 0, POINTER_FLAG_FIRSTBUTTON, POINTER_CHANGE_FIRSTBUTTON_DOWN, POINTER_CHANGE_FIRSTBUTTON_UP},
        {MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, 0, POINTER_FLAG_SECONDBUTTON, POINTER_CHANGE_SECONDBUTTON_DOWN, POINTER_CHANGE_SECONDBUTTON_UP},
        {MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0, POINTER_FLAG_THIRDBUTTON, POINTER_CHANGE_THIRDBUTTON_DOWN, POINTER_CHANGE_THIRDBUTTON_UP},
        {MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON1, POINTER_FLAG_FOURTHBUTTON, POINTER_CHANGE_FOURTHBUTTON_DOWN, POINTER_CHANGE_FOURTHBUTTON_UP},
        {MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON2, POINTER_FLAG_FIFTHBUTTON, POINTER_CHANGE_FIFTHBUTTON_DOWN, POINTER_CHANGE_FIFTHBUTTON_UP}
    };
    enabled = argc < 2 || atoi(argv[1]) != 0;
    check(!IsMouseInPointerEnabled(), "mouse-in-pointer unexpectedly initially enabled");
    if (!EnableMouseInPointer(enabled))
    {
        fprintf(stderr, "FAIL: EnableMouseInPointer(%d): error %lu\n", enabled, GetLastError());
        return 1;
    }
    check(IsMouseInPointerEnabled() == enabled, "enable/query disagree");
    check(EnableMouseInPointer(enabled), "repeated same enable choice failed");
    check(EnableMouseInPointer(enabled ? 2 : 0), "enable choice was not normalized");
    SetLastError(0);
    check(!EnableMouseInPointer(!enabled) && GetLastError() == ERROR_ACCESS_DENIED,
          "process choice was not immutable");
    check(!GetPointerInfo(0, &info), "zero pointer id accepted");
    check(!GetPointerInfo(0x7fff, &info), "unknown pointer id accepted");
    check(!GetPointerInfo(1, NULL), "null pointer info accepted");
    check(!GetPointerInfo(1, &info), "pointer frame exists before input");

    klass.lpfnWndProc = window_proc;
    klass.style = CS_DBLCLKS;
    klass.hInstance = GetModuleHandleW(NULL);
    klass.lpszClassName = L"MagicWinePointerContract";
    check(RegisterClassW(&klass), "RegisterClass failed");
    window = CreateWindowW(klass.lpszClassName, L"MagicWine pointer input verification",
                           WS_OVERLAPPEDWINDOW, 150, 150, 480, 360, NULL, NULL, klass.hInstance, NULL);
    check(window != NULL, "CreateWindow failed");
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    SetFocus(window);
    /* Suppress assertions for window activation's incidental initial motion. */
    expected_message = WM_POINTERUPDATE;
    ClientToScreen(window, &point);
    SetCursorPos(point.x, point.y);
    pump(150);
    raw.hwndTarget = window;
    check(RegisterRawInputDevices(&raw, 1, sizeof(raw)), "raw mouse registration failed");

    inject(MOUSEEVENTF_MOVE, 0, WM_POINTERUPDATE, 0, POINTER_CHANGE_NONE, 0);
    for (i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++)
    {
        inject(buttons[i].down, buttons[i].data, WM_POINTERDOWN, buttons[i].flag, buttons[i].press, 0);
        inject(MOUSEEVENTF_MOVE, 0, WM_POINTERUPDATE, buttons[i].flag, POINTER_CHANGE_NONE, 0);
        inject(buttons[i].up, buttons[i].data, WM_POINTERUP, 0, buttons[i].release, 0);
    }
    inject(MOUSEEVENTF_LEFTDOWN, 0, WM_POINTERDOWN, POINTER_FLAG_FIRSTBUTTON, POINTER_CHANGE_FIRSTBUTTON_DOWN, 0);
    inject(MOUSEEVENTF_RIGHTDOWN, 0, WM_POINTERDOWN, POINTER_FLAG_FIRSTBUTTON | POINTER_FLAG_SECONDBUTTON, POINTER_CHANGE_SECONDBUTTON_DOWN, 0);
    inject(MOUSEEVENTF_LEFTUP, 0, WM_POINTERUP, POINTER_FLAG_SECONDBUTTON, POINTER_CHANGE_FIRSTBUTTON_UP, 0);
    inject(MOUSEEVENTF_MOVE, 0, WM_POINTERUPDATE, POINTER_FLAG_SECONDBUTTON, POINTER_CHANGE_NONE, 0);
    inject(MOUSEEVENTF_RIGHTUP, 0, WM_POINTERUP, 0, POINTER_CHANGE_SECONDBUTTON_UP, 0);
    inject(MOUSEEVENTF_WHEEL, (DWORD)-WHEEL_DELTA, WM_POINTERWHEEL, 0, POINTER_CHANGE_NONE, -WHEEL_DELTA);
    inject(MOUSEEVENTF_HWHEEL, WHEEL_DELTA, WM_POINTERHWHEEL, 0, POINTER_CHANGE_NONE, WHEEL_DELTA);

    expected_message = WM_POINTERUPDATE;
    expected_buttons = 0;
    expected_change = POINTER_CHANGE_NONE;
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_MOVE;
    input.mi.dx = 3;
    before = pointer_count;
    check(SendInput(1, &input, sizeof(input)) == 1, "peek input failed");
    for (i = 0; i < 10; i++)
    {
        PeekMessageW(&message, window, WM_MOUSEMOVE, WM_MOUSEMOVE, PM_NOREMOVE);
        Sleep(2);
    }
    check(pointer_count == before, "PM_NOREMOVE dispatched pointer input");
    pump(50);
    check(pointer_count == before + !!enabled, "peek/remove duplicated or lost pointer input");
    thread = CreateThread(NULL, 0, check_other_thread, NULL, 0, NULL);
    check(thread != NULL, "cross-thread query could not start");
    if (thread)
    {
        check(WaitForSingleObject(thread, 5000) == WAIT_OBJECT_0, "cross-thread query timed out");
        CloseHandle(thread);
    }
    DestroyWindow(window);
    printf("%u-bit pointer %s: %u failures, %u pointer / %u classic / %u raw events\n",
           (unsigned)(8 * sizeof(void *)), enabled ? "enabled" : "disabled",
           failures, pointer_count, classic_count, raw_count);
    return failures ? 1 : 0;
}
