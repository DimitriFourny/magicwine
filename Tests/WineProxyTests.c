/*
 * WinHTTP public API regressions against a real Wine runtime, in both PE ABIs.
 * Copyright 2026 MagicWine contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Run with scripts/test-wine-proxy.sh. Explicit PAC tests use only loopback.
 * --expect-disabled additionally checks a host already configured without WPAD;
 * this test never changes host network policy.
 */
#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static unsigned failures;

#define check(condition, ...) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; \
} } while (0)

static void test_invalid_parameters(void)
{
    WCHAR *url = (WCHAR *)(ULONG_PTR)0xdeadbeef;
    BOOL ret;
    DWORD error;

    SetLastError(0xdeadbeef);
    ret = WinHttpDetectAutoProxyConfigUrl(0, NULL);
    error = GetLastError();
    check(!ret && error == ERROR_INVALID_PARAMETER, "zero flags and NULL: ret %d error %lu", ret, error);
    SetLastError(0xdeadbeef);
    ret = WinHttpDetectAutoProxyConfigUrl(0, &url);
    error = GetLastError();
    check(!ret && error == ERROR_INVALID_PARAMETER, "zero flags: ret %d error %lu", ret, error);
    check(url == (WCHAR *)(ULONG_PTR)0xdeadbeef, "invalid flags modified output URL");
    SetLastError(0xdeadbeef);
    ret = WinHttpDetectAutoProxyConfigUrl(WINHTTP_AUTO_DETECT_TYPE_DNS_A, NULL);
    error = GetLastError();
    check(!ret && error == ERROR_INVALID_PARAMETER, "NULL URL: ret %d error %lu", ret, error);
}

static void test_disabled_discovery(void)
{
    const DWORD flags[] = { WINHTTP_AUTO_DETECT_TYPE_DHCP, WINHTTP_AUTO_DETECT_TYPE_DNS_A,
                           WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A };
    unsigned i, pass;
    for (pass = 0; pass < 2; ++pass)
        for (i = 0; i < sizeof(flags) / sizeof(flags[0]); ++i)
        {
            WCHAR *url = (WCHAR *)(ULONG_PTR)0xdeadbeef;
            ULONGLONG start = GetTickCount64(), elapsed;
            BOOL ret;
            DWORD error;
            SetLastError(0xdeadbeef);
            ret = WinHttpDetectAutoProxyConfigUrl(flags[i], &url);
            error = GetLastError();
            elapsed = GetTickCount64() - start;
            check(!ret && error == ERROR_WINHTTP_AUTODETECTION_FAILED,
                  "disabled flags %#lx pass %u: ret %d error %lu", flags[i], pass, ret, error);
            check(url == NULL, "disabled detection returned a URL");
            check(elapsed < 2000, "disabled detection took %llu ms", (unsigned long long)elapsed);
            if (ret && url) GlobalFree(url);
        }
}

struct pac_server
{
    SOCKET listener;
    HANDLE stop;
    LONG requests;
    LONG errors;
};

static DWORD WINAPI serve_pac(void *arg)
{
    static const char script[] = "function FindProxyForURL(url, host) { return 'PROXY pac-regression.invalid:8087'; }\n";
    struct pac_server *server = arg;
    while (WaitForSingleObject(server->stop, 0) == WAIT_TIMEOUT)
    {
        fd_set readers;
        struct timeval timeout = { 0, 100000 };
        SOCKET client;
        char request[8192], response[1024];
        unsigned received = 0;
        int ready, length, sent = 0;
        DWORD receive_timeout = 5000;

        FD_ZERO(&readers);
        FD_SET(server->listener, &readers);
        ready = select(0, &readers, NULL, NULL, &timeout);
        if (!ready) continue;
        if (ready == SOCKET_ERROR) { InterlockedIncrement(&server->errors); break; }
        client = accept(server->listener, NULL, NULL);
        if (client == INVALID_SOCKET) { InterlockedIncrement(&server->errors); break; }
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char *)&receive_timeout, sizeof(receive_timeout));
        request[0] = 0;
        while (!strstr(request, "\r\n\r\n") && received < sizeof(request) - 1)
        {
            int n = recv(client, request + received, sizeof(request) - 1 - received, 0);
            if (n <= 0) break;
            received += n;
            request[received] = 0;
        }
        if (!strstr(request, "\r\n\r\n"))
        {
            InterlockedIncrement(&server->errors);
            closesocket(client);
            continue;
        }
        length = snprintf(response, sizeof(response),
                          "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                          "Content-Length: %u\r\nConnection: close\r\n\r\n%s",
                          (unsigned)strlen(script), script);
        while (sent < length)
        {
            int n = send(client, response + sent, length - sent, 0);
            if (n <= 0) break;
            sent += n;
        }
        if (sent != length) InterlockedIncrement(&server->errors);
        InterlockedIncrement(&server->requests);
        closesocket(client);
    }
    return 0;
}

static void test_explicit_pac(BOOL expect_disabled)
{
    WSADATA data;
    struct sockaddr_in address = {0};
    struct pac_server server = { INVALID_SOCKET, NULL, 0, 0 };
    HANDLE thread = NULL;
    HINTERNET session = NULL;
    int address_size = sizeof(address);
    WCHAR pac_url[128];
    unsigned i, cases = expect_disabled ? 2 : 1;

    if (WSAStartup(MAKEWORD(2, 2), &data)) { check(FALSE, "WSAStartup failed"); return; }
    server.listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (server.listener == INVALID_SOCKET) { check(FALSE, "socket failed"); goto done; }
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server.listener, (const struct sockaddr *)&address, sizeof(address)) ||
        getsockname(server.listener, (struct sockaddr *)&address, &address_size) ||
        listen(server.listener, SOMAXCONN))
    {
        check(FALSE, "loopback listener setup failed: %d", WSAGetLastError());
        goto done;
    }
    server.stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!server.stop) { check(FALSE, "CreateEvent failed"); goto done; }
    thread = CreateThread(NULL, 0, serve_pac, &server, 0, NULL);
    if (!thread) { check(FALSE, "CreateThread failed"); goto done; }
    session = WinHttpOpen(L"MagicWine proxy regression", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, 0);
    if (!session) { check(FALSE, "WinHttpOpen failed: %lu", GetLastError()); goto done; }
    check(WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000), "setting timeouts failed");
    for (i = 0; i < cases; ++i)
    {
        WINHTTP_AUTOPROXY_OPTIONS options = {0};
        WINHTTP_PROXY_INFO info = {0};
        BOOL ret;
        DWORD error;
        /* Distinct URLs require real PAC evaluation for each case. */
        swprintf(pac_url, sizeof(pac_url) / sizeof(pac_url[0]),
                 L"http://127.0.0.1:%u/proxy.pac?case=%u", ntohs(address.sin_port), i);
        options.dwFlags = WINHTTP_AUTOPROXY_CONFIG_URL;
        options.lpszAutoConfigUrl = pac_url;
        if (i)
        {
            options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
            options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
        }
        SetLastError(0xdeadbeef);
        ret = WinHttpGetProxyForUrl(session, L"https://destination.invalid/path", &options, &info);
        error = GetLastError();
        check(ret && error == ERROR_SUCCESS, "explicit PAC case %u: ret %d error %lu", i, ret, error);
        if (ret)
        {
            check(info.dwAccessType == WINHTTP_ACCESS_TYPE_NAMED_PROXY, "PAC did not return named proxy");
            check(info.lpszProxy && !wcscmp(info.lpszProxy, L"pac-regression.invalid:8087"),
                  "explicit PAC result lost%s", i ? " after disabled autodetection" : "");
        }
        GlobalFree(info.lpszProxy);
        GlobalFree(info.lpszProxyBypass);
    }

done:
    if (session) WinHttpCloseHandle(session);
    if (thread)
    {
        SetEvent(server.stop);
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
        check(server.requests == (LONG)cases, "served %ld PAC requests, expected %u", server.requests, cases);
        check(!server.errors, "PAC server encountered %ld errors", server.errors);
    }
    if (server.stop) CloseHandle(server.stop);
    if (server.listener != INVALID_SOCKET) closesocket(server.listener);
    WSACleanup();
}

int main(int argc, char **argv)
{
    BOOL expect_disabled = argc == 2 && !strcmp(argv[1], "--expect-disabled");
    if (argc > 2 || (argc == 2 && !expect_disabled))
    {
        fprintf(stderr, "Usage: %s [--expect-disabled]\n", argv[0]);
        return 2;
    }
    test_invalid_parameters();
    if (expect_disabled) test_disabled_discovery();
    test_explicit_pac(expect_disabled);
    printf("WinHTTP %u-bit API: %u failures%s\n", (unsigned)(8 * sizeof(void *)), failures,
           expect_disabled ? " (host WPAD disabled)" : "");
    return failures ? 1 : 0;
}
