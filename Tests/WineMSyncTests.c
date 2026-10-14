/* Copyright 2026 MagicWine contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Real Windows synchronization contracts, exercised in both ABIs by test-msync.sh.
 * Deadlines are hang guards, never performance assertions. No user prefix is needed.
 */
#define WINVER 0x0601
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define DEADLINE 15000
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define require(condition, ...) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fflush(stderr); \
    ExitProcess(1); \
} } while (0)

static void expect_wait(HANDLE handle, DWORD timeout, DWORD expected, const char *what)
{
    DWORD result = WaitForSingleObject(handle, timeout);
    require(result == expected, "%s: wait %#lx, expected %#lx (error %lu)",
            what, result, expected, GetLastError());
}

static HANDLE event(BOOL manual, BOOL initial)
{
    HANDLE handle = CreateEventW(NULL, manual, initial, NULL);
    require(handle != NULL, "CreateEvent: %lu", GetLastError());
    return handle;
}

static HANDLE semaphore(LONG initial, LONG maximum)
{
    HANDLE handle = CreateSemaphoreW(NULL, initial, maximum, NULL);
    require(handle != NULL, "CreateSemaphore: %lu", GetLastError());
    return handle;
}

static HANDLE mutex(BOOL owned)
{
    HANDLE handle = CreateMutexW(NULL, owned, NULL);
    require(handle != NULL, "CreateMutex: %lu", GetLastError());
    return handle;
}

static void close_handle(HANDLE handle)
{
    require(CloseHandle(handle), "CloseHandle: %lu", GetLastError());
}

static HANDLE start_thread(LPTHREAD_START_ROUTINE entry, void *argument)
{
    HANDLE thread = CreateThread(NULL, 0, entry, argument, 0, NULL);
    require(thread != NULL, "CreateThread: %lu", GetLastError());
    return thread;
}

static void join_thread(HANDLE thread, DWORD expected)
{
    DWORD code;
    expect_wait(thread, DEADLINE, WAIT_OBJECT_0, "thread termination");
    expect_wait(thread, 0, WAIT_OBJECT_0, "terminated thread stays signaled");
    require(GetExitCodeThread(thread, &code) && code == expected,
            "thread exit code, expected %lu", expected);
    close_handle(thread);
}

struct event_waiter {
    HANDLE target, ready, complete;
};

static DWORD WINAPI wait_event(void *argument)
{
    struct event_waiter *waiter = argument;
    require(ReleaseSemaphore(waiter->ready, 1, NULL), "event waiter ready");
    expect_wait(waiter->target, DEADLINE, WAIT_OBJECT_0, "event worker");
    require(ReleaseSemaphore(waiter->complete, 1, NULL), "event waiter completed");
    return 42;
}

static void test_events(void)
{
    HANDLE manual = event(TRUE, FALSE), automatic = event(FALSE, FALSE);
    HANDLE ready = semaphore(0, 2), complete = semaphore(0, 2), threads[2];
    struct event_waiter waiter = {manual, ready, complete};
    unsigned i;

    expect_wait(manual, 0, WAIT_TIMEOUT, "manual initially reset");
    expect_wait(automatic, 0, WAIT_TIMEOUT, "auto initially reset");
    for (i = 0; i < ARRAY_SIZE(threads); ++i) threads[i] = start_thread(wait_event, &waiter);
    for (i = 0; i < ARRAY_SIZE(threads); ++i)
        expect_wait(ready, DEADLINE, WAIT_OBJECT_0, "manual waiter ready");
    expect_wait(threads[0], 0, WAIT_TIMEOUT, "live thread is not signaled");
    require(SetEvent(manual), "set manual event");
    for (i = 0; i < ARRAY_SIZE(threads); ++i) {
        expect_wait(complete, DEADLINE, WAIT_OBJECT_0, "manual wakes every waiter");
        join_thread(threads[i], 42);
    }
    expect_wait(manual, 0, WAIT_OBJECT_0, "manual stays signaled");
    expect_wait(manual, 0, WAIT_OBJECT_0, "manual can be observed repeatedly");
    require(ResetEvent(manual), "reset manual event");
    expect_wait(manual, 0, WAIT_TIMEOUT, "manual reset takes effect");
    require(ResetEvent(manual), "repeated manual reset");

    require(SetEvent(automatic) && SetEvent(automatic), "set auto event twice");
    expect_wait(automatic, 0, WAIT_OBJECT_0, "auto consumes one signal");
    expect_wait(automatic, 0, WAIT_TIMEOUT, "auto signals do not accumulate");
    require(SetEvent(automatic) && ResetEvent(automatic), "reset auto event");
    expect_wait(automatic, 0, WAIT_TIMEOUT, "auto reset takes effect");
    waiter.target = automatic;
    for (i = 0; i < ARRAY_SIZE(threads); ++i) threads[i] = start_thread(wait_event, &waiter);
    for (i = 0; i < ARRAY_SIZE(threads); ++i)
        expect_wait(ready, DEADLINE, WAIT_OBJECT_0, "auto waiter ready");
    require(SetEvent(automatic), "wake first auto waiter");
    expect_wait(complete, DEADLINE, WAIT_OBJECT_0, "one auto waiter completed");
    require(SetEvent(automatic), "wake second auto waiter");
    expect_wait(complete, DEADLINE, WAIT_OBJECT_0, "second auto waiter completed");
    for (i = 0; i < ARRAY_SIZE(threads); ++i) join_thread(threads[i], 42);
    expect_wait(automatic, 0, WAIT_TIMEOUT, "both auto signals consumed exactly once");
    expect_wait(complete, 0, WAIT_TIMEOUT, "no extra event completions");
    close_handle(manual);
    close_handle(automatic);
    close_handle(ready);
    close_handle(complete);
    puts("PASS events and thread termination");
}

static void test_semaphores(void)
{
    HANDLE handle = semaphore(2, 3);
    LONG previous = -1;
    unsigned i;
    expect_wait(handle, 0, WAIT_OBJECT_0, "semaphore initial token 1");
    expect_wait(handle, 0, WAIT_OBJECT_0, "semaphore initial token 2");
    expect_wait(handle, 0, WAIT_TIMEOUT, "empty semaphore");
    require(ReleaseSemaphore(handle, 2, &previous) && previous == 0,
            "release two reports previous count zero, got %ld", previous);
    SetLastError(0);
    require(!ReleaseSemaphore(handle, 2, NULL) && GetLastError() == ERROR_TOO_MANY_POSTS,
            "semaphore maximum must reject overflow: %lu", GetLastError());
    expect_wait(handle, 0, WAIT_OBJECT_0, "overflow preserves token 1");
    expect_wait(handle, 0, WAIT_OBJECT_0, "overflow preserves token 2");
    expect_wait(handle, 0, WAIT_TIMEOUT, "overflow does not add tokens");
    for (i = 0; i < 3; ++i) {
        previous = -1;
        require(ReleaseSemaphore(handle, 1, &previous) && previous == (LONG)i,
                "previous count %ld, expected %u", previous, i);
    }
    SetLastError(0);
    require(!ReleaseSemaphore(handle, 1, NULL) && GetLastError() == ERROR_TOO_MANY_POSTS,
            "full semaphore rejects a post");
    /* Wine forwards this as an unsigned NT count. The failed release must not
     * overflow or consume the semaphore, regardless of Win32 error mapping. */
    require(!ReleaseSemaphore(handle, -1, NULL), "negative release must fail");
    for (i = 0; i < 3; ++i) expect_wait(handle, 0, WAIT_OBJECT_0, "drain maximum count");
    expect_wait(handle, 0, WAIT_TIMEOUT, "maximum count exhausted");
    close_handle(handle);
    puts("PASS semaphore counts and limits");
}

struct mutex_probe {
    HANDLE target;
    DWORD expected;
};

static DWORD WINAPI probe_mutex(void *argument)
{
    struct mutex_probe *probe = argument;
    expect_wait(probe->target, 0, probe->expected, "mutex from non-owner thread");
    if (probe->expected == WAIT_OBJECT_0 || probe->expected == WAIT_ABANDONED_0)
        require(ReleaseMutex(probe->target), "probe releases acquired mutex");
    return 0;
}

static void expect_mutex_from_thread(HANDLE target, DWORD expected)
{
    struct mutex_probe probe = {target, expected};
    join_thread(start_thread(probe_mutex, &probe), 0);
}

static DWORD WINAPI abandon_mutex(void *argument)
{
    HANDLE handle = argument;
    expect_wait(handle, DEADLINE, WAIT_OBJECT_0, "abandoning worker acquires mutex");
    expect_wait(handle, 0, WAIT_OBJECT_0, "abandoning worker acquires recursively");
    return 0;
}

static void test_mutexes(void)
{
    HANDLE handle = mutex(TRUE), blocker = event(TRUE, FALSE), objects[2];
    DWORD result;
    expect_wait(handle, 0, WAIT_OBJECT_0, "recursive mutex acquisition 2");
    expect_wait(handle, 0, WAIT_OBJECT_0, "recursive mutex acquisition 3");
    expect_mutex_from_thread(handle, WAIT_TIMEOUT);
    require(ReleaseMutex(handle), "release recursion 3");
    expect_mutex_from_thread(handle, WAIT_TIMEOUT);
    require(ReleaseMutex(handle), "release recursion 2");
    expect_mutex_from_thread(handle, WAIT_TIMEOUT);
    require(ReleaseMutex(handle), "release final recursion");
    expect_mutex_from_thread(handle, WAIT_OBJECT_0);
    SetLastError(0);
    require(!ReleaseMutex(handle) && GetLastError() == ERROR_NOT_OWNER,
            "non-owner release must fail: %lu", GetLastError());

    join_thread(start_thread(abandon_mutex, handle), 0);
    expect_wait(handle, DEADLINE, WAIT_ABANDONED_0, "abandoned recursive mutex");
    expect_wait(handle, 0, WAIT_OBJECT_0, "new owner can recurse after abandonment");
    require(ReleaseMutex(handle) && ReleaseMutex(handle), "abandoned recursion is not inherited");
    expect_mutex_from_thread(handle, WAIT_OBJECT_0);

    objects[0] = blocker;
    objects[1] = handle;
    join_thread(start_thread(abandon_mutex, handle), 0);
    result = WaitForMultipleObjects(2, objects, FALSE, DEADLINE);
    require(result == WAIT_ABANDONED_0 + 1, "wait-any abandoned index: %#lx", result);
    require(ReleaseMutex(handle), "release wait-any abandoned mutex");
    join_thread(start_thread(abandon_mutex, handle), 0);
    objects[0] = handle;
    objects[1] = blocker;
    require(WaitForMultipleObjects(2, objects, TRUE, 25) == WAIT_TIMEOUT,
            "failed wait-all must preserve abandonment for the next owner");
    require(SetEvent(blocker), "make abandoned wait-all ready");
    result = WaitForMultipleObjects(2, objects, TRUE, DEADLINE);
    require(result == WAIT_ABANDONED_0, "wait-all abandoned result: %#lx", result);
    require(ReleaseMutex(handle), "release wait-all abandoned mutex");
    close_handle(handle);
    close_handle(blocker);
    puts("PASS recursive and abandoned mutexes");
}

static void test_native_mutex_state(void)
{
    typedef LONG (WINAPI *release_mutant_fn)(HANDLE, LONG *);
    release_mutant_fn release_mutant = (release_mutant_fn)(void *)
        GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtReleaseMutant");
    HANDLE handle = mutex(TRUE);
    LONG previous, status, depth;
    require(release_mutant != NULL, "resolve NtReleaseMutant");
    expect_wait(handle, 0, WAIT_OBJECT_0, "native mutant recursion 2");
    expect_wait(handle, 0, WAIT_OBJECT_0, "native mutant recursion 3");
    for (depth = 3; depth >= 1; --depth) {
        previous = 12345;
        status = release_mutant(handle, &previous);
        require(status == 0 && previous == 1 - depth,
                "NtReleaseMutant depth %ld: status %#lx, previous %ld, expected %ld",
                depth, (unsigned long)status, previous, 1 - depth);
        expect_mutex_from_thread(handle, depth > 1 ? WAIT_TIMEOUT : WAIT_OBJECT_0);
    }
    expect_wait(handle, 0, WAIT_OBJECT_0, "native mutant can be reacquired");
    require(release_mutant(handle, NULL) == 0, "NtReleaseMutant accepts null previous-state output");
    expect_mutex_from_thread(handle, WAIT_OBJECT_0);
    close_handle(handle);
    puts("PASS native NtReleaseMutant previous-state semantics");
}

struct wait_all_worker {
    HANDLE *objects, ready;
};

static DWORD WINAPI acquire_wait_all(void *argument)
{
    struct wait_all_worker *state = argument;
    require(SetEvent(state->ready), "wait-all worker ready");
    require(WaitForMultipleObjects(4, state->objects, TRUE, DEADLINE) == WAIT_OBJECT_0,
            "wait-all wakes when other thread completes the set");
    require(ReleaseMutex(state->objects[2]), "wait-all worker owns and releases mutex");
    return 0;
}

static void test_wait_sets(void)
{
    HANDLE manual = event(TRUE, FALSE), automatic = event(FALSE, TRUE);
    HANDLE count = semaphore(1, 1), lock = mutex(FALSE);
    HANDLE any[] = {manual, automatic, count};
    HANDLE all[] = {automatic, count, lock, manual};
    struct wait_all_worker worker = {all, event(TRUE, FALSE)};
    HANDLE thread;
    DWORD result;

    result = WaitForMultipleObjects(3, any, FALSE, 0);
    require(result == WAIT_OBJECT_0 + 1, "wait-any returns first ready index: %#lx", result);
    result = WaitForMultipleObjects(3, any, FALSE, 0);
    require(result == WAIT_OBJECT_0 + 2, "wait-any consumes only selected object: %#lx", result);
    require(WaitForMultipleObjects(3, any, FALSE, 0) == WAIT_TIMEOUT, "wait-any exhausted");
    require(SetEvent(manual) && SetEvent(automatic) && ReleaseSemaphore(count, 1, NULL),
            "replenish wait-any objects");
    require(WaitForMultipleObjects(3, any, FALSE, 0) == WAIT_OBJECT_0,
            "wait-any selects lowest index when all are ready");
    require(ResetEvent(manual), "block wait-all");

    result = WaitForMultipleObjects(4, all, TRUE, 25);
    require(result == WAIT_TIMEOUT, "finite wait-all timeout: %#lx", result);
    expect_wait(automatic, 0, WAIT_OBJECT_0, "failed wait-all preserves auto event");
    expect_wait(count, 0, WAIT_OBJECT_0, "failed wait-all preserves semaphore");
    expect_mutex_from_thread(lock, WAIT_OBJECT_0);
    require(SetEvent(automatic) && ReleaseSemaphore(count, 1, NULL) && SetEvent(manual),
            "make entire wait-all set ready");
    require(WaitForMultipleObjects(4, all, TRUE, DEADLINE) == WAIT_OBJECT_0,
            "wait-all atomically acquires ready set");
    expect_wait(automatic, 0, WAIT_TIMEOUT, "successful wait-all consumes auto event");
    expect_wait(count, 0, WAIT_TIMEOUT, "successful wait-all consumes semaphore");
    expect_mutex_from_thread(lock, WAIT_TIMEOUT);
    expect_wait(manual, 0, WAIT_OBJECT_0, "successful wait-all preserves manual event");

    /* A failed wait-all must not add a recursion to an already owned mutex. */
    require(ResetEvent(manual) && SetEvent(automatic) && ReleaseSemaphore(count, 1, NULL),
            "prepare recursive wait-all timeout");
    require(WaitForMultipleObjects(4, all, TRUE, 0) == WAIT_TIMEOUT,
            "zero-timeout wait-all cannot partially acquire");
    require(ReleaseMutex(lock), "release exactly one successful wait-all ownership");
    expect_mutex_from_thread(lock, WAIT_OBJECT_0);
    expect_wait(automatic, 0, WAIT_OBJECT_0, "recursive failure preserves event");
    expect_wait(count, 0, WAIT_OBJECT_0, "recursive failure preserves semaphore");

    thread = start_thread(acquire_wait_all, &worker);
    expect_wait(worker.ready, DEADLINE, WAIT_OBJECT_0, "asynchronous wait-all startup");
    require(SetEvent(automatic) && ReleaseSemaphore(count, 1, NULL) && SetEvent(manual),
            "publish objects to waiting thread");
    join_thread(thread, 0);
    expect_wait(automatic, 0, WAIT_TIMEOUT, "asynchronous wait-all consumes event");
    expect_wait(count, 0, WAIT_TIMEOUT, "asynchronous wait-all consumes semaphore");
    expect_mutex_from_thread(lock, WAIT_OBJECT_0);
    close_handle(worker.ready);
    close_handle(manual);
    close_handle(automatic);
    close_handle(count);
    close_handle(lock);
    puts("PASS wait-any indices and wait-all atomicity/timeouts");
}

static volatile LONG apc_calls;
static ULONG_PTR apc_value;

static VOID CALLBACK record_apc(ULONG_PTR value)
{
    apc_value = value;
    InterlockedIncrement(&apc_calls);
}

static void queue_apc(ULONG_PTR value)
{
    require(QueueUserAPC(record_apc, GetCurrentThread(), value) != 0,
            "QueueUserAPC: %lu", GetLastError());
}

struct remote_apc {
    HANDLE target, request;
};

static DWORD WINAPI send_apcs(void *argument)
{
    struct remote_apc *state = argument;
    unsigned i;
    for (i = 1; i <= 32; ++i) {
        expect_wait(state->request, DEADLINE, WAIT_OBJECT_0, "remote APC request");
        require(QueueUserAPC(record_apc, state->target, 0x6000 + i) != 0,
                "cross-thread QueueUserAPC: %lu", GetLastError());
    }
    return 0;
}

static void test_apcs(void)
{
    HANDLE blocked = event(TRUE, FALSE), signaled = event(FALSE, FALSE);
    HANDLE objects[] = {blocked, signaled};
    struct remote_apc remote;
    HANDLE thread;
    unsigned i;
    queue_apc(0x1234);
    require(WaitForSingleObjectEx(blocked, 0, FALSE) == WAIT_TIMEOUT,
            "non-alertable wait remains blocked");
    require(apc_calls == 0, "non-alertable wait delivered APC");
    require(WaitForSingleObjectEx(blocked, DEADLINE, TRUE) == WAIT_IO_COMPLETION,
            "alertable single wait delivers APC");
    require(apc_calls == 1 && apc_value == 0x1234, "APC argument and call count");
    expect_wait(blocked, 0, WAIT_TIMEOUT, "APC does not signal wait object");
    queue_apc(0x2345);
    require(WaitForMultipleObjectsEx(2, objects, FALSE, DEADLINE, TRUE) == WAIT_IO_COMPLETION,
            "alertable wait-any delivers APC");
    require(apc_calls == 2 && apc_value == 0x2345, "wait-any APC data");
    queue_apc(0x3456);
    require(WaitForMultipleObjectsEx(2, objects, TRUE, DEADLINE, TRUE) == WAIT_IO_COMPLETION,
            "alertable wait-all delivers APC");
    require(apc_calls == 3 && apc_value == 0x3456, "wait-all APC data");
    queue_apc(0x4567);
    require(SleepEx(DEADLINE, TRUE) == WAIT_IO_COMPLETION, "alertable sleep delivers APC");
    require(apc_calls == 4 && apc_value == 0x4567, "sleep APC data");
    queue_apc(0x5678);
    require(SignalObjectAndWait(signaled, blocked, DEADLINE, TRUE) == WAIT_IO_COMPLETION,
            "alertable signal-and-wait delivers APC");
    require(apc_calls == 5 && apc_value == 0x5678, "signal-and-wait APC data");
    expect_wait(signaled, 0, WAIT_OBJECT_0, "APC interruption preserves completed signal");
    require(DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(),
                            &remote.target, 0, FALSE, DUPLICATE_SAME_ACCESS), "duplicate APC target");
    remote.request = event(FALSE, FALSE);
    thread = start_thread(send_apcs, &remote);
    for (i = 1; i <= 32; ++i) {
        DWORD result;
        require(SetEvent(remote.request), "request cross-thread APC");
        if (i % 3 == 0)
            result = WaitForSingleObjectEx(blocked, DEADLINE, TRUE);
        else
            result = WaitForMultipleObjectsEx(2, objects, i % 3 == 1, DEADLINE, TRUE);
        require(result == WAIT_IO_COMPLETION, "cross-thread APC interrupts wait: %#lx", result);
        require(apc_calls == (LONG)(5 + i) && apc_value == 0x6000 + i,
                "cross-thread APC ordering at %u", i);
    }
    join_thread(thread, 0);
    close_handle(remote.target);
    close_handle(remote.request);
    close_handle(blocked);
    close_handle(signaled);
    puts("PASS alertable APC delivery");
}

static void object_name(char *buffer, size_t capacity, DWORD owner, const char *kind)
{
    int length = snprintf(buffer, capacity, "Local\\MagicWineMSync-%lu-%s", owner, kind);
    require(length > 0 && (size_t)length < capacity, "named-object name length");
}

static void start_child(const wchar_t *arguments, BOOL inherit, PROCESS_INFORMATION *process)
{
    wchar_t executable[4096], command[4352];
    STARTUPINFOW startup = {0};
    DWORD length = GetModuleFileNameW(NULL, executable, (DWORD)ARRAY_SIZE(executable));
    int command_length;
    require(length && length < ARRAY_SIZE(executable), "get executable path");
    command_length = swprintf(command, ARRAY_SIZE(command), L"\"%ls\" %ls", executable, arguments);
    require(command_length > 0 && (size_t)command_length < ARRAY_SIZE(command), "child command length");
    startup.cb = sizeof(startup);
    require(CreateProcessW(executable, command, NULL, NULL, inherit, 0, NULL, NULL, &startup, process),
            "CreateProcess: %lu", GetLastError());
}

static int child_process(DWORD owner, HANDLE pipe)
{
    char name[128];
    HANDLE gate, ready, lock, done, duplicate;
    uint64_t payload;
    DWORD received;
    LONG previous = -1;
    object_name(name, sizeof(name), owner, "gate");
    gate = OpenEventA(SYNCHRONIZE, FALSE, name);
    object_name(name, sizeof(name), owner, "ready");
    ready = OpenSemaphoreA(SEMAPHORE_MODIFY_STATE, FALSE, name);
    object_name(name, sizeof(name), owner, "mutex");
    lock = OpenMutexA(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, name);
    object_name(name, sizeof(name), owner, "done");
    done = OpenEventA(EVENT_MODIFY_STATE, FALSE, name);
    require(gate && ready && lock && done, "child opens named objects: %lu", GetLastError());
    require(ReadFile(pipe, &payload, sizeof(payload), &received, NULL) && received == sizeof(payload),
            "child receives duplicated handle: %lu", GetLastError());
    close_handle(pipe);
    duplicate = (HANDLE)(uintptr_t)payload;
    expect_wait(duplicate, 0, WAIT_TIMEOUT, "cross-process duplicate initially reset");
    expect_wait(lock, 0, WAIT_TIMEOUT, "named mutex remains owned by parent");
    require(ReleaseSemaphore(ready, 1, &previous) && previous == 0,
            "child posts named semaphore, previous %ld", previous);
    expect_wait(gate, DEADLINE, WAIT_OBJECT_0, "named manual event from parent");
    expect_wait(gate, 0, WAIT_OBJECT_0, "named manual event remains signaled");
    expect_wait(lock, DEADLINE, WAIT_OBJECT_0, "named mutex ownership crosses processes");
    require(ReleaseMutex(lock), "child releases named mutex");
    expect_wait(duplicate, DEADLINE, WAIT_OBJECT_0, "duplicated anonymous event from parent");
    expect_wait(duplicate, 0, WAIT_TIMEOUT, "cross-process auto event consumed");
    require(SetEvent(done), "child signals named auto event");
    close_handle(gate);
    close_handle(ready);
    close_handle(lock);
    close_handle(done);
    close_handle(duplicate);
    return 37;
}

static void test_processes(void)
{
    char name[128];
    wchar_t arguments[128];
    HANDLE gate, ready, lock, done, original = event(FALSE, FALSE), local, remote;
    HANDLE pipe_read, pipe_write, termination[2];
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
    PROCESS_INFORMATION process = {0};
    DWORD owner = GetCurrentProcessId(), written, code;
    uint64_t payload;
    int command_length;

    object_name(name, sizeof(name), owner, "gate");
    gate = CreateEventA(NULL, TRUE, FALSE, name);
    require(gate && GetLastError() != ERROR_ALREADY_EXISTS, "create unique named gate");
    object_name(name, sizeof(name), owner, "ready");
    ready = CreateSemaphoreA(NULL, 0, 1, name);
    require(ready && GetLastError() != ERROR_ALREADY_EXISTS, "create unique named semaphore");
    object_name(name, sizeof(name), owner, "mutex");
    lock = CreateMutexA(NULL, TRUE, name);
    require(lock && GetLastError() != ERROR_ALREADY_EXISTS, "create unique owned named mutex");
    object_name(name, sizeof(name), owner, "done");
    done = CreateEventA(NULL, FALSE, FALSE, name);
    require(done && GetLastError() != ERROR_ALREADY_EXISTS, "create unique named completion");
    require(DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), &local,
                            0, FALSE, DUPLICATE_SAME_ACCESS), "duplicate local event");
    close_handle(original);
    require(CreatePipe(&pipe_read, &pipe_write, &attributes, 0), "create child control pipe");
    require(SetHandleInformation(pipe_write, HANDLE_FLAG_INHERIT, 0), "parent keeps pipe writer");
    command_length = swprintf(arguments, ARRAY_SIZE(arguments), L"--child %lu %llu",
                              owner, (unsigned long long)(uintptr_t)pipe_read);
    require(command_length > 0 && (size_t)command_length < ARRAY_SIZE(arguments), "child arguments length");
    start_child(arguments, TRUE, &process);
    close_handle(pipe_read);
    require(DuplicateHandle(GetCurrentProcess(), local, process.hProcess, &remote,
                            0, FALSE, DUPLICATE_SAME_ACCESS), "duplicate handle into child");
    payload = (uint64_t)(uintptr_t)remote;
    require(WriteFile(pipe_write, &payload, sizeof(payload), &written, NULL) && written == sizeof(payload),
            "send child duplicated handle");
    close_handle(pipe_write);
    expect_wait(ready, DEADLINE, WAIT_OBJECT_0, "child has opened named objects");
    expect_wait(process.hProcess, 0, WAIT_TIMEOUT, "live process is not signaled");
    expect_wait(process.hThread, 0, WAIT_TIMEOUT, "live primary thread is not signaled");
    require(ReleaseMutex(lock) && SetEvent(gate) && SetEvent(local), "release child protocol");
    close_handle(local); /* The child's duplicate alone now keeps the anonymous event alive. */
    expect_wait(done, DEADLINE, WAIT_OBJECT_0, "named auto event from child");
    expect_wait(done, 0, WAIT_TIMEOUT, "named auto event resets across processes");
    termination[0] = process.hThread;
    termination[1] = process.hProcess;
    require(WaitForMultipleObjects(2, termination, TRUE, DEADLINE) == WAIT_OBJECT_0,
            "wait-all observes process and primary-thread termination");
    require(GetExitCodeProcess(process.hProcess, &code) && code == 37, "child exit code must be 37");
    expect_wait(process.hProcess, 0, WAIT_OBJECT_0, "terminated process remains signaled");
    expect_wait(process.hThread, 0, WAIT_OBJECT_0, "terminated primary thread remains signaled");
    expect_mutex_from_thread(lock, WAIT_OBJECT_0);
    close_handle(process.hThread);
    close_handle(process.hProcess);
    close_handle(gate);
    close_handle(ready);
    close_handle(lock);
    close_handle(done);
    puts("PASS cross-process named objects, duplication, and termination");
}

struct handoff {
    HANDLE request, reply;
    unsigned iterations;
    volatile LONG sent, received;
};

static DWORD WINAPI handoff_worker(void *argument)
{
    struct handoff *state = argument;
    unsigned i;
    expect_wait(state->request, DEADLINE, WAIT_OBJECT_0, "initial handoff request");
    for (i = 1; i <= state->iterations; ++i) {
        require(InterlockedCompareExchange(&state->sent, 0, 0) == (LONG)i,
                "handoff request ordering at %u", i);
        InterlockedExchange(&state->received, (LONG)i);
        if (i == state->iterations)
            require(SetEvent(state->reply), "final handoff reply");
        else
            require(SignalObjectAndWait(state->reply, state->request, DEADLINE, FALSE) == WAIT_OBJECT_0,
                    "worker signal-and-wait handoff %u", i);
    }
    return 0;
}

static void run_handoffs(unsigned iterations, BOOL benchmark)
{
    struct handoff state = {0};
    HANDLE thread;
    LARGE_INTEGER frequency, start, finish;
    unsigned i;
    state.request = event(FALSE, FALSE);
    state.reply = event(FALSE, FALSE);
    state.iterations = iterations;
    require(QueryPerformanceFrequency(&frequency) && frequency.QuadPart > 0, "performance frequency");
    thread = start_thread(handoff_worker, &state);
    require(QueryPerformanceCounter(&start), "start counter");
    for (i = 1; i <= iterations; ++i) {
        InterlockedExchange(&state.sent, (LONG)i);
        require(SignalObjectAndWait(state.request, state.reply, DEADLINE, FALSE) == WAIT_OBJECT_0,
                "parent signal-and-wait handoff %u", i);
        require(InterlockedCompareExchange(&state.received, 0, 0) == (LONG)i,
                "handoff reply ordering at %u", i);
    }
    require(QueryPerformanceCounter(&finish), "finish counter");
    join_thread(thread, 0);
    expect_wait(state.request, 0, WAIT_TIMEOUT, "handoff requests consumed");
    expect_wait(state.reply, 0, WAIT_TIMEOUT, "handoff replies consumed");
    if (benchmark) {
        double seconds = (double)(finish.QuadPart - start.QuadPart) / (double)frequency.QuadPart;
        printf("BENCH signal-and-wait abi=%u WINEMSYNC=%s round_trips=%u total_ms=%.3f ns_per_handoff=%.1f\n",
               (unsigned)(sizeof(void *) * 8), getenv("WINEMSYNC") ? getenv("WINEMSYNC") : "unset",
               iterations, seconds * 1000.0, seconds * 1.0e9 / (2.0 * iterations));
    }
    close_handle(state.request);
    close_handle(state.reply);
}

static void test_signal_and_wait(void)
{
    HANDLE blocked = event(TRUE, FALSE), lock = mutex(TRUE), count = semaphore(0, 1);
    require(SignalObjectAndWait(lock, blocked, 0, FALSE) == WAIT_TIMEOUT,
            "signal-and-wait timeout after mutex release");
    expect_mutex_from_thread(lock, WAIT_OBJECT_0);
    require(SignalObjectAndWait(count, blocked, 0, FALSE) == WAIT_TIMEOUT,
            "signal-and-wait timeout after semaphore release");
    expect_wait(count, 0, WAIT_OBJECT_0, "timed-out signal-and-wait still posts semaphore");
    expect_wait(count, 0, WAIT_TIMEOUT, "signal-and-wait posts exactly once");
    run_handoffs(1024, FALSE);
    close_handle(blocked);
    close_handle(lock);
    close_handle(count);
    puts("PASS signal-and-wait release semantics and repeated handoff races");
}

#define CONTENDERS 6
#define CONTENTION_ROUNDS 2000
struct contention {
    HANDLE gate, ready, lock, slots;
    LONG protected_count;
    volatile LONG owners, in_slots;
};

static DWORD WINAPI contend(void *argument)
{
    struct contention *state = argument;
    unsigned i;
    require(ReleaseSemaphore(state->ready, 1, NULL), "contention worker ready");
    expect_wait(state->gate, DEADLINE, WAIT_OBJECT_0, "contention start gate");
    for (i = 0; i < CONTENTION_ROUNDS; ++i) {
        LONG active;
        expect_wait(state->lock, DEADLINE, WAIT_OBJECT_0, "contended mutex");
        require(InterlockedIncrement(&state->owners) == 1, "mutex allowed simultaneous owners");
        ++state->protected_count;
        if (!(i % 127)) SwitchToThread();
        require(InterlockedDecrement(&state->owners) == 0, "mutex owner accounting");
        require(ReleaseMutex(state->lock), "release contended mutex");
        expect_wait(state->slots, DEADLINE, WAIT_OBJECT_0, "contended semaphore");
        active = InterlockedIncrement(&state->in_slots);
        require(active >= 1 && active <= 3, "semaphore admitted %ld simultaneous holders", active);
        if (!(i % 127)) SwitchToThread();
        require(InterlockedDecrement(&state->in_slots) >= 0, "semaphore holder accounting");
        require(ReleaseSemaphore(state->slots, 1, NULL), "release contended semaphore");
    }
    return 0;
}

static void test_contention(void)
{
    struct contention state = {0};
    HANDLE threads[CONTENDERS];
    unsigned i;
    state.gate = event(TRUE, FALSE);
    state.ready = semaphore(0, CONTENDERS);
    state.lock = mutex(FALSE);
    state.slots = semaphore(3, 3);
    for (i = 0; i < ARRAY_SIZE(threads); ++i) threads[i] = start_thread(contend, &state);
    for (i = 0; i < ARRAY_SIZE(threads); ++i)
        expect_wait(state.ready, DEADLINE, WAIT_OBJECT_0, "contention worker startup");
    require(SetEvent(state.gate), "release contention workers");
    for (i = 0; i < ARRAY_SIZE(threads); ++i) join_thread(threads[i], 0);
    require(state.protected_count == CONTENDERS * CONTENTION_ROUNDS,
            "protected increments %ld, expected %d", state.protected_count, CONTENDERS * CONTENTION_ROUNDS);
    require(state.owners == 0 && state.in_slots == 0, "contention leaves no owners");
    for (i = 0; i < 3; ++i) expect_wait(state.slots, 0, WAIT_OBJECT_0, "contention preserves tokens");
    expect_wait(state.slots, 0, WAIT_TIMEOUT, "contention creates no extra tokens");
    close_handle(state.gate);
    close_handle(state.ready);
    close_handle(state.lock);
    close_handle(state.slots);
    puts("PASS bounded repeated mutex/semaphore contention");
}

#define DUPLICATE_BOUNDARY_COUNT 65568
#define GROWTH_WORKERS 4
/* More than 128 pages even with the old 16-byte slots and 16-KiB host pages. */
#define GROWTH_OBJECTS_PER_WORKER 33792
#define STRESS_DEADLINE 120000

static void probe_live_event(HANDLE original, HANDLE *recycled)
{
    HANDLE probe;
    /* Free a lower allocation first so an incorrectly zero reference count on
     * the still-live original cannot hide behind the allocator's free hint. */
    close_handle(*recycled);
    *recycled = event(TRUE, FALSE);
    probe = event(TRUE, TRUE);
    expect_wait(original, 0, WAIT_TIMEOUT, "live event must not alias a newly signaled object");
    expect_wait(*recycled, 0, WAIT_TIMEOUT, "recycled event remains independent");
    require(SetEvent(original) && ResetEvent(probe), "change independent event states");
    expect_wait(original, 0, WAIT_OBJECT_0, "resetting new object must not reset live event");
    expect_wait(probe, 0, WAIT_TIMEOUT, "new event reset");
    require(ResetEvent(original), "restore original event state");
    close_handle(probe);
}

static void test_duplicate_boundary(void)
{
    HANDLE recycled = event(TRUE, FALSE), original = event(TRUE, FALSE);
    HANDLE *duplicates = HeapAlloc(GetProcessHeap(), 0,
                                   DUPLICATE_BOUNDARY_COUNT * sizeof(*duplicates));
    unsigned i;
    require(duplicates != NULL, "allocate duplicate-handle boundary array");
    expect_wait(recycled, 0, WAIT_TIMEOUT, "cache lower allocation");
    expect_wait(original, 0, WAIT_TIMEOUT, "cache original event");
    for (i = 0; i < DUPLICATE_BOUNDARY_COUNT; ++i) {
        require(DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), &duplicates[i],
                                0, FALSE, DUPLICATE_SAME_ACCESS),
                "duplicate boundary handle %u: %lu", i, GetLastError());
        expect_wait(duplicates[i], 0, WAIT_TIMEOUT, "cache each distinct duplicate handle");
        if (i >= 65520) probe_live_event(original, &recycled);
    }
    require(SetEvent(original), "signal more than 65535 cached duplicates");
    for (i = 0; i < DUPLICATE_BOUNDARY_COUNT; ++i)
        expect_wait(duplicates[i], 0, WAIT_OBJECT_0, "all duplicate handles observe one live event");
    require(ResetEvent(original), "reset more than 65535 cached duplicates");
    for (i = 0; i < DUPLICATE_BOUNDARY_COUNT; ++i) {
        expect_wait(duplicates[i], 0, WAIT_TIMEOUT, "duplicate retains reset state");
        close_handle(duplicates[i]);
        if (i < 64) probe_live_event(original, &recycled);
    }
    probe_live_event(original, &recycled);
    require(HeapFree(GetProcessHeap(), 0, duplicates), "free duplicate-handle array");
    close_handle(original);
    close_handle(recycled);
    puts("PASS 65568 cached duplicate handles preserve live event identity across allocation/release");
}

struct object_growth {
    HANDLE start, ready, verify;
    HANDLE *objects;
};

static DWORD WINAPI grow_objects(void *argument)
{
    struct object_growth *state = argument;
    unsigned i;
    expect_wait(state->start, STRESS_DEADLINE, WAIT_OBJECT_0, "object growth start");
    for (i = 0; i < GROWTH_OBJECTS_PER_WORKER; ++i) {
        state->objects[i] = event(TRUE, !!(i & 1));
        expect_wait(state->objects[i], 0, (i & 1) ? WAIT_OBJECT_0 : WAIT_TIMEOUT,
                    "concurrent creation maps independent initial state");
    }
    require(ReleaseSemaphore(state->ready, 1, NULL), "all worker objects remain live");
    expect_wait(state->verify, STRESS_DEADLINE, WAIT_OBJECT_0, "hold all pages across growth boundary");
    for (i = 0; i < GROWTH_OBJECTS_PER_WORKER; ++i) {
        expect_wait(state->objects[i], 0, (i & 1) ? WAIT_OBJECT_0 : WAIT_TIMEOUT,
                    "mapping growth preserves existing objects");
        require(SetEvent(state->objects[i]), "signal object after mapping growth");
        expect_wait(state->objects[i], 0, WAIT_OBJECT_0, "grown object signal");
        require(ResetEvent(state->objects[i]), "reset object after mapping growth");
        expect_wait(state->objects[i], 0, WAIT_TIMEOUT, "grown object reset");
        close_handle(state->objects[i]);
        state->objects[i] = event(TRUE, !(i & 1));
        expect_wait(state->objects[i], 0, (i & 1) ? WAIT_TIMEOUT : WAIT_OBJECT_0,
                    "concurrent reused handles do not expose stale cache entries");
    }
    for (i = 0; i < GROWTH_OBJECTS_PER_WORKER; ++i) close_handle(state->objects[i]);
    return 0;
}

static void test_object_growth(void)
{
    HANDLE start = event(TRUE, FALSE), ready = semaphore(0, GROWTH_WORKERS);
    HANDLE verify = event(TRUE, FALSE), threads[GROWTH_WORKERS];
    HANDLE *objects = HeapAlloc(GetProcessHeap(), 0,
                                GROWTH_WORKERS * GROWTH_OBJECTS_PER_WORKER * sizeof(*objects));
    struct object_growth workers[GROWTH_WORKERS];
    unsigned i;
    require(objects != NULL, "allocate concurrent object-growth handle array");
    for (i = 0; i < GROWTH_WORKERS; ++i) {
        workers[i].start = start;
        workers[i].ready = ready;
        workers[i].verify = verify;
        workers[i].objects = objects + i * GROWTH_OBJECTS_PER_WORKER;
        threads[i] = start_thread(grow_objects, &workers[i]);
    }
    require(SetEvent(start), "start concurrent shared mapping growth");
    for (i = 0; i < GROWTH_WORKERS; ++i)
        expect_wait(ready, STRESS_DEADLINE, WAIT_OBJECT_0, "all object-growth allocations complete");
    require(SetEvent(verify), "validate and recycle simultaneously live objects");
    require(WaitForMultipleObjects(GROWTH_WORKERS, threads, TRUE, STRESS_DEADLINE) == WAIT_OBJECT_0,
            "bounded concurrent mapping verification finishes");
    for (i = 0; i < GROWTH_WORKERS; ++i) join_thread(threads[i], 0);
    require(HeapFree(GetProcessHeap(), 0, objects), "free object-growth array");
    close_handle(start);
    close_handle(ready);
    close_handle(verify);
    printf("PASS concurrent mapping growth and reuse of %u simultaneously live objects\n",
           (unsigned)(GROWTH_WORKERS * GROWTH_OBJECTS_PER_WORKER));
}

#define EXIT_CACHE_OBJECTS 8192
#define EXIT_CACHE_ROUNDS 8

static int cache_exit_child(DWORD owner, BOOL abrupt)
{
    char name[128];
    HANDLE ready, live;
    unsigned i;
    object_name(name, sizeof(name), owner, "cache-ready");
    ready = OpenEventA(EVENT_MODIFY_STATE, FALSE, name);
    object_name(name, sizeof(name), owner, "cache-live");
    live = OpenEventA(SYNCHRONIZE, FALSE, name);
    require(ready && live, "cache child opens parent objects");
    expect_wait(live, 0, WAIT_TIMEOUT, "cache child sees retained parent object");
    for (i = 0; i < EXIT_CACHE_OBJECTS; ++i) {
        HANDLE anonymous = event(TRUE, !!(i & 1)), duplicate;
        expect_wait(anonymous, 0, (i & 1) ? WAIT_OBJECT_0 : WAIT_TIMEOUT,
                    "cache child anonymous object state");
        require(DuplicateHandle(GetCurrentProcess(), live, GetCurrentProcess(), &duplicate,
                                0, FALSE, DUPLICATE_SAME_ACCESS), "cache child duplicate");
        expect_wait(duplicate, 0, WAIT_TIMEOUT, "cache child retained-parent duplicate");
        /* Intentionally leave both handles cached and open until process death.
         * This tests OS/backend teardown, not explicit CloseHandle cleanup. */
    }
    require(SetEvent(ready), "cache child reports live outstanding handles");
    if (abrupt) {
        HANDLE park = event(TRUE, FALSE);
        expect_wait(park, STRESS_DEADLINE, WAIT_TIMEOUT, "cache child termination guard");
        ExitProcess(2); /* Parent must terminate this child before the guard expires. */
    }
    ExitProcess(0);
    return 0;
}

static void test_process_cache_churn(void)
{
    char name[128];
    wchar_t arguments[128];
    DWORD owner = GetCurrentProcessId(), code;
    HANDLE recycled = event(TRUE, FALSE), ready, live;
    unsigned i;
    object_name(name, sizeof(name), owner, "cache-ready");
    ready = CreateEventA(NULL, TRUE, FALSE, name);
    require(ready && GetLastError() != ERROR_ALREADY_EXISTS, "create cache-churn ready event");
    object_name(name, sizeof(name), owner, "cache-live");
    live = CreateEventA(NULL, TRUE, FALSE, name);
    require(live && GetLastError() != ERROR_ALREADY_EXISTS, "create retained cache-churn event");
    expect_wait(live, 0, WAIT_TIMEOUT, "cache retained parent event");
    for (i = 0; i < EXIT_CACHE_ROUNDS; ++i) {
        PROCESS_INFORMATION process = {0};
        HANDLE startup[2];
        int length;
        require(ResetEvent(ready), "reset child cache-ready event");
        length = swprintf(arguments, ARRAY_SIZE(arguments), L"--cache-child %lu %u", owner, i & 1);
        require(length > 0 && (size_t)length < ARRAY_SIZE(arguments), "cache child arguments length");
        start_child(arguments, FALSE, &process);
        startup[0] = ready;
        startup[1] = process.hProcess;
        require(WaitForMultipleObjects(2, startup, FALSE, STRESS_DEADLINE) == WAIT_OBJECT_0,
                "cache child fills handles before exiting");
        if (i & 1) require(TerminateProcess(process.hProcess, 73), "terminate only owned cache child");
        expect_wait(process.hProcess, STRESS_DEADLINE, WAIT_OBJECT_0, "cache child process death");
        require(GetExitCodeProcess(process.hProcess, &code) && code == ((i & 1) ? 73u : 0u),
                "cache child exit status");
        close_handle(process.hThread);
        close_handle(process.hProcess);
        probe_live_event(live, &recycled);
    }
    close_handle(live);
    close_handle(ready);
    close_handle(recycled);
    puts("PASS retained-object identity through eight normal/terminated process cache-churn cycles");
}

int main(int argc, char **argv)
{
    BOOL benchmark = FALSE;
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    if (argc == 4 && !strcmp(argv[1], "--child"))
        return child_process((DWORD)strtoul(argv[2], NULL, 10),
                             (HANDLE)(uintptr_t)strtoull(argv[3], NULL, 10));
    if (argc == 4 && !strcmp(argv[1], "--cache-child"))
        return cache_exit_child((DWORD)strtoul(argv[2], NULL, 10), !!strtoul(argv[3], NULL, 10));
    if (argc == 2 && !strcmp(argv[1], "--benchmark")) benchmark = TRUE;
    else if (argc != 1) {
        fprintf(stderr, "Usage: %s [--benchmark]\n", argv[0]);
        return 2;
    }
    printf("MagicWine MSync regression: %u-bit WINEMSYNC=%s\n", (unsigned)(sizeof(void *) * 8),
           getenv("WINEMSYNC") ? getenv("WINEMSYNC") : "unset");
    test_events();
    test_semaphores();
    test_mutexes();
    test_native_mutex_state();
    test_wait_sets();
    test_apcs();
    test_processes();
    test_signal_and_wait();
    test_contention();
    test_duplicate_boundary();
    test_object_growth();
    test_process_cache_churn();
    if (benchmark) run_handoffs(20000, TRUE);
    printf("PASS: MagicWine MSync synchronization regression (%u-bit)\n", (unsigned)(sizeof(void *) * 8));
    return 0;
}
