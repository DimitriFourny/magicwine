/*
 * Deterministic tests of Wine's actual macOS WinHTTP Unix helper.
 * Copyright 2026 MagicWine contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Run scripts/test-wine-proxy.sh --native /patched/wine/source /wine/build.
 * Only the host dictionary acquisition is replaced, within this test binary.
 * No host network settings or production environment overrides are used.
 */
#include <SystemConfiguration/SystemConfiguration.h>
#include <stdio.h>
#include <stdlib.h>

static CFDictionaryRef fixture;

static CFDictionaryRef copy_test_proxies(SCDynamicStoreRef store)
{
    (void)store;
    return fixture ? CFRetain(fixture) : NULL;
}

#define SCDynamicStoreCopyProxies copy_test_proxies
#include "unixlib.c"
#undef SCDynamicStoreCopyProxies

static unsigned failures, cases;

#define check(condition, ...) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; \
} } while (0)

static void test_policy(const char *name, CFTypeRef value, BOOL readable,
                        NTSTATUS expected_status, BOOL expected_enabled)
{
    CFMutableDictionaryRef dictionary = NULL;
    unsigned i, count = 1;
    unixlib_entry_t entries[2] = { __wine_unix_call_funcs[unix_get_proxy_autodiscovery] };

#ifdef _WIN64
    entries[count++] = __wine_unix_call_wow64_funcs[unix_get_proxy_autodiscovery];
#endif
    if (readable)
    {
        dictionary = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
        if (!dictionary) abort();
        if (value) CFDictionarySetValue(dictionary, kSCPropNetProxiesProxyAutoDiscoveryEnable, value);
    }
    fixture = dictionary;
    for (i = 0; i < count; ++i)
    {
        /* Canaries catch an accidental pointer or native-sized BOOL layout. */
        struct
        {
            unsigned before;
            struct proxy_autodiscovery_params params;
            unsigned after;
        } data = { 0x12345678, { -1 }, 0x87654321 };
        NTSTATUS status = entries[i](&data.params);
        check(status == expected_status, "%s ABI %u status %#x expected %#x",
              name, i, (unsigned)status, (unsigned)expected_status);
        check(data.params.enabled == expected_enabled, "%s ABI %u enabled %d expected %d",
              name, i, data.params.enabled, expected_enabled);
        check(data.before == 0x12345678 && data.after == 0x87654321, "%s ABI %u overwrote parameter bounds", name, i);
        cases++;
    }
    fixture = NULL;
    if (dictionary) CFRelease(dictionary);
}

int main(void)
{
    int zero = 0, one = 1, two = 2, negative = -1;
    double fractional = 0.5;
    CFNumberRef numbers[] = {
        CFNumberCreate(NULL, kCFNumberIntType, &zero),
        CFNumberCreate(NULL, kCFNumberIntType, &one),
        CFNumberCreate(NULL, kCFNumberIntType, &two),
        CFNumberCreate(NULL, kCFNumberIntType, &negative),
        CFNumberCreate(NULL, kCFNumberDoubleType, &fractional)
    };
    unsigned i;
    for (i = 0; i < sizeof(numbers) / sizeof(numbers[0]); ++i)
        if (!numbers[i]) abort();

    test_policy("unreadable", NULL, FALSE, STATUS_NOT_SUPPORTED, TRUE);
    test_policy("missing", NULL, TRUE, STATUS_SUCCESS, FALSE);
    test_policy("number false", numbers[0], TRUE, STATUS_SUCCESS, FALSE);
    test_policy("number true", numbers[1], TRUE, STATUS_SUCCESS, TRUE);
    test_policy("boolean false", kCFBooleanFalse, TRUE, STATUS_SUCCESS, FALSE);
    test_policy("boolean true", kCFBooleanTrue, TRUE, STATUS_SUCCESS, TRUE);
    test_policy("malformed string", CFSTR("1"), TRUE, STATUS_NOT_SUPPORTED, TRUE);
    test_policy("malformed number", numbers[2], TRUE, STATUS_NOT_SUPPORTED, TRUE);
    test_policy("negative number", numbers[3], TRUE, STATUS_NOT_SUPPORTED, TRUE);
    test_policy("fractional number", numbers[4], TRUE, STATUS_NOT_SUPPORTED, TRUE);
    /* A fresh call must reflect changed policy, not reuse the preceding value. */
    test_policy("enabled again", numbers[1], TRUE, STATUS_SUCCESS, TRUE);
    test_policy("disabled after enabled", NULL, TRUE, STATUS_SUCCESS, FALSE);
    test_policy("unreadable after disabled", NULL, FALSE, STATUS_NOT_SUPPORTED, TRUE);

    for (i = 0; i < sizeof(numbers) / sizeof(numbers[0]); ++i) CFRelease(numbers[i]);
    printf("WinHTTP native policy: %u cases, %u failures\n", cases, failures);
    return failures ? 1 : 0;
}
