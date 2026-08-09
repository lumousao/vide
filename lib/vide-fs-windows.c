#ifdef _WIN32
#include <stdio.h>
#include <wchar.h>
#include <windows.h>

static int remove_tree(const wchar_t *path)
{
    WIN32_FIND_DATAW data;
    wchar_t pattern[32768];
    wchar_t child[32768];
    HANDLE find;
    _snwprintf(pattern, sizeof(pattern) / sizeof(*pattern), L"%ls\\*", path);
    find = FindFirstFileW(pattern, &data);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L".."))
                continue;
            _snwprintf(child, sizeof(child) / sizeof(*child), L"%ls\\%ls", path, data.cFileName);
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (remove_tree(child) < 0) {
                    FindClose(find);
                    return -1;
                }
            } else if (!DeleteFileW(child)) {
                FindClose(find);
                return -1;
            }
        } while (FindNextFileW(find, &data));
        FindClose(find);
    }
    return RemoveDirectoryW(path) ? 0 : -1;
}

static void join_path(const wchar_t *root, const wchar_t *relative, wchar_t *out, size_t size)
{
    if (relative[0] == L'\\' || (relative[0] && relative[1] == L':'))
        _snwprintf(out, size, L"%ls", relative);
    else
        _snwprintf(out, size, L"%ls\\%ls", root, relative);
    out[size - 1] = L'\0';
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t old_path[32768], new_path[32768];
    if (argc < 4) {
        fwprintf(stderr, L"usage: vide-fs ROOT OP PATH [NEW]\n");
        return 2;
    }
    join_path(argv[1], argv[3], old_path, sizeof(old_path) / sizeof(*old_path));
    if (argc == 5)
        join_path(argv[1], argv[4], new_path, sizeof(new_path) / sizeof(*new_path));
    if (_wcsicmp(argv[2], L"create-file") == 0) {
        HANDLE file = CreateFileW(old_path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                                  FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) {
            fwprintf(stderr, L"create-file: %ls: error %lu\n", old_path, GetLastError());
            return 1;
        }
        CloseHandle(file);
    } else if (_wcsicmp(argv[2], L"create-dir") == 0) {
        if (!CreateDirectoryW(old_path, NULL)) {
            fwprintf(stderr, L"create-dir: %ls: error %lu\n", old_path, GetLastError());
            return 1;
        }
    } else if (_wcsicmp(argv[2], L"delete") == 0) {
        DWORD attrs = GetFileAttributesW(old_path);
        if (attrs == INVALID_FILE_ATTRIBUTES ||
            ((attrs & FILE_ATTRIBUTE_DIRECTORY) && remove_tree(old_path) < 0) ||
            (!(attrs & FILE_ATTRIBUTE_DIRECTORY) && !DeleteFileW(old_path))) {
            fwprintf(stderr, L"delete: %ls: error %lu\n", old_path, GetLastError());
            return 1;
        }
    } else if (_wcsicmp(argv[2], L"rename") == 0 && argc == 5) {
        if (!MoveFileExW(old_path, new_path, MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH)) {
            fwprintf(stderr, L"rename: %ls: error %lu\n", old_path, GetLastError());
            return 1;
        }
    } else {
        fwprintf(stderr, L"vide-fs: unsupported operation\n");
        return 1;
    }
    fwprintf(stdout, L"OK\n");
    return 0;
}
#else
int main(void) { return 2; }
#endif
