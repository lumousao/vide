#ifdef _WIN32
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <windows.h>

static void emit_utf8(const char *kind, const wchar_t *root, const wchar_t *name)
{
    wchar_t full[32768];
    char path[131072];
    char frame[131200];
    int wide_len;
    int path_len;
    int frame_len;
    if (name && *name)
        _snwprintf(full, sizeof(full) / sizeof(*full), L"%ls\\%ls", root, name);
    else
        _snwprintf(full, sizeof(full) / sizeof(*full), L"%ls", root);
    full[(sizeof(full) / sizeof(*full)) - 1] = L'\0';
    path_len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1,
                                   path, sizeof(path), NULL, NULL);
    if (path_len <= 0)
        return;
    --path_len;
    frame_len = _snprintf(frame, sizeof(frame), "P%s%d:", kind, path_len);
    if (frame_len < 0 || frame_len + path_len >= (int)sizeof(frame))
        return;
    fwrite(frame, 1, (size_t)frame_len, stdout);
    fwrite(path, 1, (size_t)path_len, stdout);
    fflush(stdout);
}

static void emit_error(const wchar_t *root, const char *reason)
{
    char path[32768];
    int n = WideCharToMultiByte(CP_UTF8, 0, root, -1, path, sizeof(path), NULL, NULL);
    char detail[65536];
    if (n <= 0)
        return;
    n = _snprintf(detail, sizeof(detail), "%s: %s", path, reason);
    if (n < 0)
        return;
    printf("PERROR%d:", n);
    fwrite(detail, 1, (size_t)n, stdout);
    fflush(stdout);
}

int wmain(int argc, wchar_t **argv)
{
    if (argc != 2) {
        fwprintf(stderr, L"usage: vide-watch PROJECT_ROOT\n");
        return 2;
    }
    HANDLE root = CreateFileW(argv[1], FILE_LIST_DIRECTORY,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING,
                              FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (root == INVALID_HANDLE_VALUE) {
        emit_error(argv[1], "cannot open project root");
        return 2;
    }
    for (;;) {
        BYTE buffer[64 * 1024];
        DWORD bytes = 0;
        if (!ReadDirectoryChangesW(root, buffer, sizeof(buffer), TRUE,
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_ATTRIBUTES,
                &bytes, NULL, NULL)) {
            DWORD error = GetLastError();
            if (error == ERROR_PATH_NOT_FOUND || error == ERROR_INVALID_HANDLE)
                emit_error(argv[1], "ROOT_LOST: project root is unavailable");
            else
                emit_error(argv[1], "ReadDirectoryChangesW failed");
            CloseHandle(root);
            return 2;
        }
        if (!bytes)
            continue;
        for (FILE_NOTIFY_INFORMATION *item = (FILE_NOTIFY_INFORMATION *)buffer;;) {
            wchar_t name[32768];
            size_t count = item->FileNameLength / sizeof(wchar_t);
            const wchar_t *kind = L"WRITE";
            DWORD attrs;
            if (count >= sizeof(name) / sizeof(*name))
                count = sizeof(name) / sizeof(*name) - 1;
            wmemcpy(name, item->FileName, count);
            name[count] = L'\0';
            attrs = GetFileAttributesW(name);
            if (item->Action == FILE_ACTION_ADDED)
                kind = L"CREATE";
            else if (item->Action == FILE_ACTION_REMOVED)
                kind = L"DELETE";
            else if (item->Action == FILE_ACTION_RENAMED_OLD_NAME)
                kind = L"MOVE_OUT";
            else if (item->Action == FILE_ACTION_RENAMED_NEW_NAME)
                kind = L"MOVE_IN";
            if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY))
                kind = L"DIR";
            {
                char kind8[16];
                WideCharToMultiByte(CP_UTF8, 0, kind, -1, kind8, sizeof(kind8), NULL, NULL);
                emit_utf8(kind8, argv[1], name);
            }
            if (!item->NextEntryOffset)
                break;
            item = (FILE_NOTIFY_INFORMATION *)((BYTE *)item + item->NextEntryOffset);
        }
    }
}
#else
int main(void) { return 2; }
#endif
