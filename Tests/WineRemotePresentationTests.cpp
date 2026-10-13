/*
 * Cross-process D3D11 presentation regressions for real Wine graphics backends.
 * Copyright 2026 MagicWine contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Renderer readback verifies the actual GPU output. Successful Present alone
 * does not certify owner-window composition; the runner supports a visual hold
 * for separate window capture/inspection.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static unsigned failures;
static unsigned visual_hold_ms;
static const char window_class[] = "MagicWineRemotePresentation";

#define check(condition, ...) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); ++failures; \
} } while (0)

static void pump(unsigned milliseconds)
{
    ULONGLONG deadline = GetTickCount64() + milliseconds;
    do {
        MSG message;
        while (PeekMessageA(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageA(&message);
        }
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    } while (GetTickCount64() < deadline);
}

static HWND create_window(const char *title, HWND parent, int x, int y, int width, int height)
{
    return CreateWindowA(window_class, title,
        (parent ? WS_CHILD : WS_OVERLAPPEDWINDOW) | WS_VISIBLE,
        x, y, width, height, parent, nullptr, GetModuleHandleA(nullptr), nullptr);
}

static void render(HWND window, const char *label, bool expect_foreign_root)
{
    DWORD owner = 0, root_owner = 0;
    GetWindowThreadProcessId(window, &owner);
    GetWindowThreadProcessId(GetAncestor(window, GA_ROOT), &root_owner);
    check((root_owner != GetCurrentProcessId()) == expect_foreign_root,
          "%s wrong ownership: target %lu root %lu self %lu", label, owner, root_owner, GetCurrentProcessId());
    printf("%s target=%p owner=%lu root_owner=%lu self=%lu\n", label, window, owner, root_owner, GetCurrentProcessId());

    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    IDXGIDevice *dxgi_device = nullptr;
    IDXGIAdapter *adapter = nullptr;
    IDXGIFactory2 *factory = nullptr;
    IDXGISwapChain1 *swapchain = nullptr;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
    check(SUCCEEDED(hr), "%s D3D11CreateDevice %#lx", label, hr);
    if (FAILED(hr)) return;
    hr = device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgi_device));
    if (SUCCEEDED(hr)) hr = dxgi_device->GetAdapter(&adapter);
    if (SUCCEEDED(hr)) hr = adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void **>(&factory));
    check(SUCCEEDED(hr), "%s obtaining factory %#lx", label, hr);
    if (SUCCEEDED(hr)) {
        /* Chromium 126 ANGLE's Factory2 HWND descriptor, not a game-only path. */
        DXGI_SWAP_CHAIN_DESC1 desc = {};
        desc.Width = 301;
        desc.Height = 199;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT | DXGI_USAGE_SHADER_INPUT | DXGI_USAGE_BACK_BUFFER;
        desc.BufferCount = 1;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_SEQUENTIAL;
        desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
        hr = factory->CreateSwapChainForHwnd(device, window, &desc, nullptr, nullptr, &swapchain);
        check(SUCCEEDED(hr), "%s CreateSwapChainForHwnd %#lx", label, hr);
    }
    for (unsigned pass = 0; swapchain && pass != 3; ++pass) {
        UINT width = pass == 1 ? 400 : 301, height = pass == 1 ? 250 : 199;
        if (pass) {
            hr = swapchain->ResizeBuffers(1, width, height, DXGI_FORMAT_UNKNOWN, 0);
            check(SUCCEEDED(hr), "%s ResizeBuffers pass %u %#lx", label, pass, hr);
            if (FAILED(hr)) break;
        }
        ID3D11Texture2D *buffer = nullptr, *readback = nullptr;
        ID3D11RenderTargetView *view = nullptr;
        hr = swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&buffer));
        if (SUCCEEDED(hr)) hr = device->CreateRenderTargetView(buffer, nullptr, &view);
        check(SUCCEEDED(hr), "%s render target pass %u %#lx", label, pass, hr);
        if (SUCCEEDED(hr)) {
            /* Saturated components avoid tolerance masking or color-space ambiguity. */
            const float colors[][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}};
            context->ClearRenderTargetView(view, colors[pass]);
            D3D11_TEXTURE2D_DESC desc = {};
            buffer->GetDesc(&desc);
            check(desc.Width == width && desc.Height == height, "%s wrong buffer size after resize", label);
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            desc.MiscFlags = 0;
            hr = device->CreateTexture2D(&desc, nullptr, &readback);
            if (SUCCEEDED(hr)) {
                context->CopyResource(readback, buffer);
                D3D11_MAPPED_SUBRESOURCE map = {};
                hr = context->Map(readback, 0, D3D11_MAP_READ, 0, &map);
                if (SUCCEEDED(hr)) {
                    const BYTE *pixel = static_cast<const BYTE *>(map.pData) + (height / 2) * map.RowPitch + (width / 2) * 4;
                    const BYTE expected[][4] = {{0, 0, 255, 255}, {0, 255, 0, 255}, {255, 0, 0, 255}};
                    check(!memcmp(pixel, expected[pass], 4), "%s readback pass %u BGRA=%u,%u,%u,%u", label, pass,
                          pixel[0], pixel[1], pixel[2], pixel[3]);
                    context->Unmap(readback, 0);
                }
            }
            check(SUCCEEDED(hr), "%s GPU readback pass %u %#lx", label, pass, hr);
            hr = swapchain->Present(0, 0);
            check(SUCCEEDED(hr), "%s Present pass %u %#lx", label, pass, hr);
            pump(pass == 2 && visual_hold_ms ? visual_hold_ms : 100);
        }
        if (readback) readback->Release();
        if (view) view->Release();
        if (buffer) buffer->Release();
    }
    if (swapchain) swapchain->Release();
    if (factory) factory->Release();
    if (adapter) adapter->Release();
    if (dxgi_device) dxgi_device->Release();
    context->Release();
    device->Release();
    fflush(stdout);
}

static void worker(HWND root, HWND child)
{
    render(root, "foreign root", true);
    render(child, "foreign inset child", true);
    HWND local_child = create_window("Renderer-owned child", root, 80, 60, 301, 199);
    check(local_child != nullptr, "CreateWindow under foreign root: %lu", GetLastError());
    if (local_child) {
        render(local_child, "local child under foreign root", true);
        SetWindowPos(local_child, HWND_TOP, 125, 85, 400, 250, 0);
        ShowWindow(local_child, SW_HIDE);
        pump(50);
        SetWindowPos(local_child, nullptr, 0, 0, 0, 0, SWP_NOZORDER);
        ShowWindow(local_child, SW_SHOW);
        SetWindowPos(local_child, HWND_TOP, 80, 60, 301, 199, 0);
        render(local_child, "restored local child under foreign root", true);
        HWND second_root = create_window("Reparented presentation", nullptr, 100, 450, 460, 330);
        check(second_root != nullptr, "second root creation failed");
        if (second_root) {
            SetParent(local_child, second_root);
            render(local_child, "reparented local child", false);
            DestroyWindow(second_root);
        } else DestroyWindow(local_child);
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    SetProcessDPIAware();
    WNDCLASSA cls = {};
    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA(nullptr);
    cls.lpszClassName = window_class;
    check(RegisterClassA(&cls) != 0, "window class registration failed");
    if (argc == 5 && !strcmp(argv[1], "--worker")) {
        visual_hold_ms = static_cast<unsigned>(strtoul(argv[4], nullptr, 10));
        worker(reinterpret_cast<HWND>(strtoull(argv[2], nullptr, 16)),
               reinterpret_cast<HWND>(strtoull(argv[3], nullptr, 16)));
    } else {
        if (argc == 2 && !strcmp(argv[1], "--visual")) visual_hold_ms = 5000;
        else if (argc != 1) return 2;
        HWND control = create_window("Local presentation control", nullptr, 60, 60, 420, 320);
        HWND root = create_window("Foreign-root presentation", nullptr, 500, 60, 520, 400);
        HWND child = create_window("Foreign-child presentation", root, 35, 45, 301, 199);
        check(control && root && child, "owner window creation failed");
        if (!control || !root || !child) return 1;
        render(control, "same-process root", false);
        char executable[MAX_PATH], command[MAX_PATH + 100];
        GetModuleFileNameA(nullptr, executable, sizeof(executable));
        snprintf(command, sizeof(command), "\"%s\" --worker %llx %llx %u", executable,
                 static_cast<unsigned long long>(reinterpret_cast<ULONG_PTR>(root)),
                 static_cast<unsigned long long>(reinterpret_cast<ULONG_PTR>(child)), visual_hold_ms);
        STARTUPINFOA startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        BOOL started = CreateProcessA(nullptr, command, nullptr, nullptr, TRUE, 0, nullptr, nullptr, &startup, &process);
        check(started, "worker creation failed: %lu", GetLastError());
        if (started) {
            CloseHandle(process.hThread);
            ULONGLONG deadline = GetTickCount64() + 60000;
            while (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT && GetTickCount64() < deadline) pump(10);
            DWORD code = STILL_ACTIVE;
            GetExitCodeProcess(process.hProcess, &code);
            check(code == 0, "remote renderer exit %lu", code);
            if (code == STILL_ACTIVE) TerminateProcess(process.hProcess, 2);
            CloseHandle(process.hProcess);
        }
        /* Owner remains responsive and reusable after renderer teardown. */
        pump(100);
        render(root, "owner after renderer exit", false);
        DestroyWindow(root);
        DestroyWindow(control);
    }
    printf("Remote presentation %u-bit: %u failures\n", static_cast<unsigned>(sizeof(void *) * 8), failures);
    return failures ? 1 : 0;
}
