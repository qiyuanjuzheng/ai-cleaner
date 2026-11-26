#if defined(_WIN32)

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include "CPlatformSupport.h"

#include <windows.h>
#include <winioctl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <knownfolders.h>
#include <aclapi.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef FOFX_RECYCLEONDELETE
#define FOFX_RECYCLEONDELETE 0x00080000
#endif
#ifndef FOFX_EARLYFAILURE
#define FOFX_EARLYFAILURE 0x00100000
#endif
#ifndef TSF_DELETE_RECYCLE_IF_POSSIBLE
#define TSF_DELETE_RECYCLE_IF_POSSIBLE 0x0080
#endif
#ifndef IO_REPARSE_TAG_SYMLINK
#define IO_REPARSE_TAG_SYMLINK 0xA000000CL
#endif
#ifndef IO_REPARSE_TAG_MOUNT_POINT
#define IO_REPARSE_TAG_MOUNT_POINT 0xA0000003L
#endif

#define AICL_HR_RECYCLE_SIZE_TOO_BIG  ((HRESULT)0x80270022L)
#define AICL_HR_RECYCLE_FORCE_NUKE    ((HRESULT)0x80270023L)
#define AICL_HR_RECYCLE_BIN_NOT_FOUND ((HRESULT)0x80270024L)

static int32_t copy_cstr(const char *src, char *dst, size_t cap) {
    if (!src || !dst || cap == 0) return -1;
    size_t len = strlen(src);
    if (len >= cap) return -1;
    memcpy(dst, src, len + 1);
    return (int32_t)len;
}

static int32_t wide_to_utf8_buf(const wchar_t *wide, char *out_buf, size_t out_cap) {
    if (!wide || !out_buf || out_cap == 0) return -1;
    int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (needed <= 0 || (size_t)needed > out_cap) return -1;
    int written = WideCharToMultiByte(CP_UTF8, 0, wide, -1, out_buf, (int)out_cap, NULL, NULL);
    if (written <= 0) return -1;
    return written - 1;
}

static bool is_ascii_alpha(wchar_t c) {
    return (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z');
}

/* Converts UTF-8 path to normalized Win32 UTF-16 path.
   Normalizes '/' -> '\\', strips leading '\\' from '\\C:\\...' (Swift URL.path form),
   and optionally prepends '\\\\?\\' for long paths (>= 248 chars). */
static wchar_t *utf8_to_wide_path(const char *utf8_path, bool allow_long_prefix, bool strip_long_prefix) {
    if (!utf8_path || utf8_path[0] == '\0') return NULL;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, NULL, 0);
    if (wlen <= 0) return NULL;

    wchar_t *raw = (wchar_t *)malloc((size_t)(wlen + 16) * sizeof(wchar_t));
    if (!raw) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, raw, wlen) <= 0) {
        free(raw);
        return NULL;
    }

    for (int i = 0; i < wlen - 1; ++i) {
        if (raw[i] == L'/') raw[i] = L'\\';
    }

    wchar_t *start = raw;
    size_t len = wcslen(start);

    /* Swift URL.path on Windows often looks like "/C:/Users/..." -> "\C:\Users\..." */
    if (len >= 3 && start[0] == L'\\' && is_ascii_alpha(start[1]) && start[2] == L':') {
        start += 1;
        len -= 1;
    }

    if (strip_long_prefix && len >= 4 && wcsncmp(start, L"\\\\?\\", 4) == 0) {
        if (len >= 8 && _wcsnicmp(start + 4, L"UNC\\", 4) == 0) {
            /* \\?\UNC\server\share -> \\server\share */
            wchar_t *unc = (wchar_t *)malloc((len - 4 + 1) * sizeof(wchar_t));
            if (!unc) {
                free(raw);
                return NULL;
            }
            unc[0] = L'\\';
            unc[1] = L'\\';
            wcscpy(unc + 2, start + 8);
            free(raw);
            return unc;
        }
        start += 4;
        len -= 4;
    }

    if (allow_long_prefix && len >= 248 && is_ascii_alpha(start[0]) && start[1] == L':' && start[2] == L'\\') {
        wchar_t *prefixed = (wchar_t *)malloc((len + 5) * sizeof(wchar_t));
        if (!prefixed) {
            free(raw);
            return NULL;
        }
        wcscpy(prefixed, L"\\\\?\\");
        wcscat(prefixed, start);
        free(raw);
        return prefixed;
    }

    if (start != raw) {
        memmove(raw, start, (len + 1) * sizeof(wchar_t));
    }
    return raw;
}

static void filetime_to_unix(int64_t ticks, int64_t *out_sec, int32_t *out_nsec) {
    const int64_t epoch_diff = 116444736000000000LL;
    int64_t rel = ticks - epoch_diff;
    int64_t sec = rel / 10000000LL;
    int64_t rem = rel % 10000000LL;
    if (rem < 0) {
        sec -= 1;
        rem += 10000000LL;
    }
    *out_sec = sec;
    *out_nsec = (int32_t)(rem * 100LL);
}

int32_t aicl_file_identity(const char *utf8_path, aicl_file_identity_t *out) {
    if (!utf8_path || !out) return ERROR_INVALID_PARAMETER;
    memset(out, 0, sizeof(*out));

    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) {
        out->error_code = ERROR_INVALID_PARAMETER;
        return ERROR_INVALID_PARAMETER;
    }

    bool have_read_control = true;
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT;
    HANDLE h = CreateFileW(
        wpath,
        FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        flags,
        NULL
    );
    if (h == INVALID_HANDLE_VALUE && GetLastError() == ERROR_ACCESS_DENIED) {
        have_read_control = false;
        h = CreateFileW(
            wpath,
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL,
            OPEN_EXISTING,
            flags,
            NULL
        );
    }
    free(wpath);

    if (h == INVALID_HANDLE_VALUE) {
        DWORD err = GetLastError();
        out->error_code = (int32_t)err;
        return (int32_t)err;
    }

    FILE_BASIC_INFO basic;
    memset(&basic, 0, sizeof(basic));
    if (!GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic))) {
        DWORD err = GetLastError();
        CloseHandle(h);
        out->error_code = (int32_t)err;
        return (int32_t)err;
    }

    FILE_STANDARD_INFO std_info;
    memset(&std_info, 0, sizeof(std_info));
    if (GetFileInformationByHandleEx(h, FileStandardInfo, &std_info, sizeof(std_info))) {
        out->size = (int64_t)std_info.EndOfFile.QuadPart;
    }

    FILE_ID_INFO id_info;
    memset(&id_info, 0, sizeof(id_info));
    if (GetFileInformationByHandleEx(h, FileIdInfo, &id_info, sizeof(id_info))) {
        out->volume_id = (uint64_t)id_info.VolumeSerialNumber;
        memcpy(&out->file_id_low, id_info.FileId.Identifier, 8);
        memcpy(&out->file_id_high, id_info.FileId.Identifier + 8, 8);
    } else {
        BY_HANDLE_FILE_INFORMATION bhfi;
        memset(&bhfi, 0, sizeof(bhfi));
        if (GetFileInformationByHandle(h, &bhfi)) {
            out->volume_id = (uint64_t)bhfi.dwVolumeSerialNumber;
            out->file_id_low = (((uint64_t)bhfi.nFileIndexHigh) << 32) | (uint64_t)bhfi.nFileIndexLow;
            out->file_id_high = 0;
            if (out->size == 0) {
                out->size = (int64_t)((((uint64_t)bhfi.nFileSizeHigh) << 32) | (uint64_t)bhfi.nFileSizeLow);
            }
        }
    }

    DWORD attrs = basic.FileAttributes;
    out->is_hidden_or_system = (attrs & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)) != 0;

    if ((attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        FILE_ATTRIBUTE_TAG_INFO tag_info;
        memset(&tag_info, 0, sizeof(tag_info));
        if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag_info, sizeof(tag_info))) {
            out->reparse_tag = (uint32_t)tag_info.ReparseTag;
        }
        if (out->reparse_tag == (uint32_t)IO_REPARSE_TAG_SYMLINK) {
            out->kind = AICL_FILE_KIND_SYMLINK;
        } else {
            out->kind = AICL_FILE_KIND_REPARSE_POINT;
        }
    } else if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        out->kind = AICL_FILE_KIND_DIRECTORY;
    } else {
        DWORD ftype = GetFileType(h);
        if (ftype == FILE_TYPE_DISK) {
            out->kind = AICL_FILE_KIND_REGULAR;
        } else if (ftype == FILE_TYPE_PIPE) {
            out->kind = AICL_FILE_KIND_FIFO;
        } else if (ftype == FILE_TYPE_CHAR) {
            out->kind = AICL_FILE_KIND_DEVICE;
        } else {
            out->kind = AICL_FILE_KIND_OTHER;
        }
    }

    filetime_to_unix((int64_t)basic.LastWriteTime.QuadPart, &out->modified_sec, &out->modified_nsec);
    if (basic.ChangeTime.QuadPart > 0) {
        out->has_changed = true;
        filetime_to_unix((int64_t)basic.ChangeTime.QuadPart, &out->changed_sec, &out->changed_nsec);
    }
    if (basic.CreationTime.QuadPart > 0) {
        out->has_created = true;
        filetime_to_unix((int64_t)basic.CreationTime.QuadPart, &out->created_sec, &out->created_nsec);
    }

    if (have_read_control) {
        PSID owner_sid = NULL;
        PSECURITY_DESCRIPTOR sd = NULL;
        if (GetSecurityInfo(h, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner_sid, NULL, NULL, NULL, &sd) == ERROR_SUCCESS) {
            if (owner_sid != NULL) {
                LPWSTR sid_wstr = NULL;
                if (ConvertSidToStringSidW(owner_sid, &sid_wstr) && sid_wstr != NULL) {
                    if (wide_to_utf8_buf(sid_wstr, out->sid, sizeof(out->sid)) > 0) {
                        out->has_sid = true;
                    }
                    LocalFree(sid_wstr);
                }
            }
            if (sd != NULL) {
                LocalFree(sd);
            }
        }
    }

    CloseHandle(h);
    out->error_code = 0;
    return 0;
}

int32_t aicl_current_principal(uint32_t *out_uid, char *out_sid, size_t sid_cap) {
    (void)out_uid;
    if (!out_sid || sid_cap == 0) return 0;

    HANDLE token = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return 0;
    }

    DWORD needed = 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &needed);
    if (needed == 0) {
        CloseHandle(token);
        return 0;
    }

    PTOKEN_USER user = (PTOKEN_USER)malloc(needed);
    if (!user) {
        CloseHandle(token);
        return 0;
    }

    int32_t result = 0;
    if (GetTokenInformation(token, TokenUser, user, needed, &needed) && user->User.Sid != NULL) {
        LPWSTR sid_wstr = NULL;
        if (ConvertSidToStringSidW(user->User.Sid, &sid_wstr) && sid_wstr != NULL) {
            if (wide_to_utf8_buf(sid_wstr, out_sid, sid_cap) > 0) {
                result = 2;
            }
            LocalFree(sid_wstr);
        }
    }

    free(user);
    CloseHandle(token);
    return result;
}

aicl_disk_capacity_t aicl_disk_capacity(const char *utf8_path) {
    aicl_disk_capacity_t result = {0, 0, false};
    wchar_t *wpath = utf8_to_wide_path(utf8_path, false, true);
    if (!wpath) return result;

    ULARGE_INTEGER avail_caller, total_bytes, total_free;
    if (GetDiskFreeSpaceExW(wpath, &avail_caller, &total_bytes, &total_free)) {
        uint64_t t = total_bytes.QuadPart;
        uint64_t a = avail_caller.QuadPart;
        if (t > (uint64_t)INT64_MAX) t = (uint64_t)INT64_MAX;
        if (a > (uint64_t)INT64_MAX) a = (uint64_t)INT64_MAX;
        result.total_bytes = (int64_t)t;
        result.available_bytes = (int64_t)a;
        result.ok = true;
    }
    free(wpath);
    return result;
}

bool aicl_has_active_file_lock(const char *utf8_path) {
    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) return false;

    HANDLE h = CreateFileW(
        wpath,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT,
        NULL
    );
    if (h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
        free(wpath);
        return false;
    }
    DWORD err = GetLastError();
    if (err == ERROR_SHARING_VIOLATION || err == ERROR_LOCK_VIOLATION) {
        free(wpath);
        return true;
    }
    if (err == ERROR_ACCESS_DENIED) {
        HANDLE h_ro = CreateFileW(
            wpath,
            GENERIC_READ,
            0,
            NULL,
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT,
            NULL
        );
        if (h_ro != INVALID_HANDLE_VALUE) {
            CloseHandle(h_ro);
            free(wpath);
            return false;
        }
        DWORD err2 = GetLastError();
        free(wpath);
        return err2 == ERROR_SHARING_VIOLATION || err2 == ERROR_LOCK_VIOLATION;
    }
    free(wpath);
    return false;
}

int32_t aicl_resolve_real_path(const char *utf8_path, char *out_buf, size_t out_cap) {
    if (!utf8_path || !out_buf || out_cap == 0) return -1;
    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) return -1;

    HANDLE h = CreateFileW(
        wpath,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        NULL
    );
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) return -1;

    DWORD needed = GetFinalPathNameByHandleW(h, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (needed == 0) {
        CloseHandle(h);
        return -1;
    }

    wchar_t *final_buf = (wchar_t *)malloc((size_t)(needed + 2) * sizeof(wchar_t));
    if (!final_buf) {
        CloseHandle(h);
        return -1;
    }

    DWORD written = GetFinalPathNameByHandleW(h, final_buf, needed + 1, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (written == 0 || written > needed) {
        free(final_buf);
        return -1;
    }

    const wchar_t *clean = final_buf;
    wchar_t *unc_buf = NULL;
    if (written >= 4 && wcsncmp(final_buf, L"\\\\?\\", 4) == 0) {
        if (written >= 8 && _wcsnicmp(final_buf + 4, L"UNC\\", 4) == 0) {
            unc_buf = (wchar_t *)malloc((size_t)(written - 4 + 2) * sizeof(wchar_t));
            if (unc_buf) {
                unc_buf[0] = L'\\';
                unc_buf[1] = L'\\';
                wcscpy(unc_buf + 2, final_buf + 8);
                clean = unc_buf;
            }
        } else {
            clean = final_buf + 4;
        }
    }

    int32_t res = wide_to_utf8_buf(clean, out_buf, out_cap);
    if (unc_buf) free(unc_buf);
    free(final_buf);
    return res;
}

int32_t aicl_get_env(const char *utf8_name, char *out_buf, size_t out_cap) {
    if (!utf8_name || !out_buf || out_cap == 0) return -1;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8_name, -1, NULL, 0);
    if (wlen <= 0) return -1;
    wchar_t *wname = (wchar_t *)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wname) return -1;
    MultiByteToWideChar(CP_UTF8, 0, utf8_name, -1, wname, wlen);

    DWORD needed = GetEnvironmentVariableW(wname, NULL, 0);
    if (needed == 0) {
        free(wname);
        return -1;
    }
    wchar_t *wval = (wchar_t *)malloc((size_t)(needed + 1) * sizeof(wchar_t));
    if (!wval) {
        free(wname);
        return -1;
    }
    DWORD got = GetEnvironmentVariableW(wname, wval, needed);
    free(wname);
    if (got == 0 || got >= needed) {
        free(wval);
        return -1;
    }
    int32_t res = wide_to_utf8_buf(wval, out_buf, out_cap);
    free(wval);
    return res;
}

typedef DWORD (WINAPI *aicl_get_temp_path2_fn)(DWORD BufferLength, LPWSTR Buffer);

static int32_t known_folder_utf8(REFKNOWNFOLDERID rfid, char *out_buf, size_t out_cap) {
    PWSTR path = NULL;
    if (FAILED(SHGetKnownFolderPath(rfid, 0, NULL, &path)) || path == NULL) {
        return -1;
    }
    int32_t res = wide_to_utf8_buf(path, out_buf, out_cap);
    CoTaskMemFree(path);
    return res;
}

int32_t aicl_get_known_path(int32_t kind, char *out_buf, size_t out_cap) {
    if (!out_buf || out_cap == 0) return -1;
    switch (kind) {
        case AICL_KNOWN_PATH_HOME: {
            int32_t res = known_folder_utf8(&FOLDERID_Profile, out_buf, out_cap);
            if (res > 0) return res;
            return aicl_get_env("USERPROFILE", out_buf, out_cap);
        }
        case AICL_KNOWN_PATH_WIN_ROAMING_APPDATA: {
            int32_t res = known_folder_utf8(&FOLDERID_RoamingAppData, out_buf, out_cap);
            if (res > 0) return res;
            return aicl_get_env("APPDATA", out_buf, out_cap);
        }
        case AICL_KNOWN_PATH_WIN_LOCAL_APPDATA: {
            int32_t res = known_folder_utf8(&FOLDERID_LocalAppData, out_buf, out_cap);
            if (res > 0) return res;
            return aicl_get_env("LOCALAPPDATA", out_buf, out_cap);
        }
        case AICL_KNOWN_PATH_USER_TEMP: {
            wchar_t wbuf[MAX_PATH + 64];
            DWORD got = 0;
            HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
            if (k32) {
                aicl_get_temp_path2_fn fn = (aicl_get_temp_path2_fn)(void *)GetProcAddress(k32, "GetTempPath2W");
                if (fn) {
                    got = fn((DWORD)_countof(wbuf), wbuf);
                }
            }
            if (got == 0 || got >= _countof(wbuf)) {
                got = GetTempPathW((DWORD)_countof(wbuf), wbuf);
            }
            if (got == 0 || got >= _countof(wbuf)) return -1;
            return wide_to_utf8_buf(wbuf, out_buf, out_cap);
        }
        case AICL_KNOWN_PATH_EXECUTABLE: {
            wchar_t wbuf[32768];
            DWORD got = GetModuleFileNameW(NULL, wbuf, (DWORD)_countof(wbuf));
            if (got == 0 || got >= _countof(wbuf)) return -1;
            return wide_to_utf8_buf(wbuf, out_buf, out_cap);
        }
        default:
            return -1;
    }
}

struct aicl_ro_file {
    HANDLE handle;
};

aicl_ro_file_t *aicl_ro_file_open(const char *utf8_path) {
    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) return NULL;

    HANDLE h = CreateFileW(
        wpath,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT,
        NULL
    );
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) return NULL;

    FILE_BASIC_INFO basic;
    memset(&basic, 0, sizeof(basic));
    if (!GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic))
        || (basic.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0
        || GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        return NULL;
    }

    aicl_ro_file_t *file = (aicl_ro_file_t *)malloc(sizeof(aicl_ro_file_t));
    if (!file) {
        CloseHandle(h);
        return NULL;
    }
    file->handle = h;
    return file;
}

int64_t aicl_ro_file_read(aicl_ro_file_t *file, uint8_t *buf, size_t count) {
    if (!file || !buf || count == 0) return 0;
    size_t total = 0;
    while (total < count) {
        size_t remaining = count - total;
        DWORD chunk = remaining > 0x7FFFFFFFUL ? 0x7FFFFFFFUL : (DWORD)remaining;
        DWORD read_now = 0;
        if (!ReadFile(file->handle, buf + total, chunk, &read_now, NULL)) {
            return total > 0 ? (int64_t)total : -1;
        }
        if (read_now == 0) break;
        total += (size_t)read_now;
    }
    return (int64_t)total;
}

int64_t aicl_ro_file_size(aicl_ro_file_t *file) {
    if (!file) return -1;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(file->handle, &sz)) return -1;
    return (int64_t)sz.QuadPart;
}

bool aicl_ro_file_seek(aicl_ro_file_t *file, uint64_t offset) {
    if (!file) return false;
    LARGE_INTEGER pos;
    pos.QuadPart = (LONGLONG)offset;
    return SetFilePointerEx(file->handle, pos, NULL, FILE_BEGIN) != 0;
}

void aicl_ro_file_close(aicl_ro_file_t *file) {
    if (!file) return;
    CloseHandle(file->handle);
    free(file);
}

bool aicl_list_directory(const char *utf8_path, aicl_dir_entry_cb cb, void *ctx) {
    if (!utf8_path || !cb) return false;
    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) return false;
    DWORD attributes = GetFileAttributesW(wpath);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        free(wpath);
        return false;
    }

    size_t len = wcslen(wpath);
    wchar_t *pattern = (wchar_t *)malloc((len + 4) * sizeof(wchar_t));
    if (!pattern) {
        free(wpath);
        return false;
    }
    wcscpy(pattern, wpath);
    if (len > 0 && pattern[len - 1] != L'\\') {
        wcscat(pattern, L"\\*");
    } else {
        wcscat(pattern, L"*");
    }
    free(wpath);

    WIN32_FIND_DATAW fdata;
    HANDLE h = FindFirstFileExW(
        pattern,
        FindExInfoBasic,
        &fdata,
        FindExSearchNameMatch,
        NULL,
        FIND_FIRST_EX_LARGE_FETCH
    );
    DWORD find_error = GetLastError();
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) return find_error == ERROR_FILE_NOT_FOUND;

    char name_utf8[1024];
    do {
        const wchar_t *wn = fdata.cFileName;
        if (wn[0] == L'.' && (wn[1] == L'\0' || (wn[1] == L'.' && wn[2] == L'\0'))) continue;
        if (wide_to_utf8_buf(wn, name_utf8, sizeof(name_utf8)) <= 0 || !cb(name_utf8, ctx)) {
            FindClose(h);
            return false;
        }
    } while (FindNextFileW(h, &fdata));

    bool complete = GetLastError() == ERROR_NO_MORE_FILES;
    FindClose(h);
    return complete;
}

int32_t aicl_volume_case_sensitive(const char *utf8_path) {
    (void)utf8_path;
    return 0;
}

/* MARK: - Windows IFileOperation Recycle Bin with PreDeleteItem Guard */

typedef struct {
    const IFileOperationProgressSinkVtbl *lpVtbl;
    LONG ref_count;
    bool rejected_non_recycle;
    bool recycled;
    wchar_t dest_path[32768];
} aicl_trash_sink_t;

static HRESULT STDMETHODCALLTYPE sink_QueryInterface(IFileOperationProgressSink *This, REFIID riid, void **ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IFileOperationProgressSink)) {
        *ppv = This;
        IFileOperationProgressSink_AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE sink_AddRef(IFileOperationProgressSink *This) {
    aicl_trash_sink_t *self = (aicl_trash_sink_t *)This;
    return (ULONG)InterlockedIncrement(&self->ref_count);
}

static ULONG STDMETHODCALLTYPE sink_Release(IFileOperationProgressSink *This) {
    aicl_trash_sink_t *self = (aicl_trash_sink_t *)This;
    return (ULONG)InterlockedDecrement(&self->ref_count);
}

static HRESULT STDMETHODCALLTYPE sink_StartOperations(IFileOperationProgressSink *This) {
    (void)This;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_FinishOperations(IFileOperationProgressSink *This, HRESULT hrResult) {
    (void)This;
    (void)hrResult;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PreRenameItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, LPCWSTR pszNewName
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)pszNewName;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PostRenameItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, LPCWSTR pszNewName, HRESULT hrRename, IShellItem *psiNewlyCreated
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)pszNewName; (void)hrRename; (void)psiNewlyCreated;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PreMoveItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, IShellItem *psiDest, LPCWSTR pszNewName
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)psiDest; (void)pszNewName;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PostMoveItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, IShellItem *psiDest, LPCWSTR pszNewName, HRESULT hrMove, IShellItem *psiNewlyCreated
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)psiDest; (void)pszNewName; (void)hrMove; (void)psiNewlyCreated;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PreCopyItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, IShellItem *psiDest, LPCWSTR pszNewName
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)psiDest; (void)pszNewName;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PostCopyItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, IShellItem *psiDest, LPCWSTR pszNewName, HRESULT hrCopy, IShellItem *psiNewlyCreated
) {
    (void)This; (void)dwFlags; (void)psiItem; (void)psiDest; (void)pszNewName; (void)hrCopy; (void)psiNewlyCreated;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PreDeleteItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem
) {
    (void)psiItem;
    aicl_trash_sink_t *self = (aicl_trash_sink_t *)This;
    if ((dwFlags & TSF_DELETE_RECYCLE_IF_POSSIBLE) == 0) {
        self->rejected_non_recycle = true;
        return E_ABORT;
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PostDeleteItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiItem, HRESULT hrDelete, IShellItem *psiNewlyCreated
) {
    (void)dwFlags; (void)psiItem;
    aicl_trash_sink_t *self = (aicl_trash_sink_t *)This;
    if (SUCCEEDED(hrDelete) && psiNewlyCreated != NULL) {
        self->recycled = true;
        PWSTR name = NULL;
        if (SUCCEEDED(IShellItem_GetDisplayName(psiNewlyCreated, SIGDN_FILESYSPATH, &name)) && name != NULL) {
            wcsncpy_s(self->dest_path, _countof(self->dest_path), name, _TRUNCATE);
            CoTaskMemFree(name);
        }
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PreNewItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiDest, LPCWSTR pszNewName
) {
    (void)This; (void)dwFlags; (void)psiDest; (void)pszNewName;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PostNewItem(
    IFileOperationProgressSink *This, DWORD dwFlags, IShellItem *psiDest, LPCWSTR pszNewName, LPCWSTR pszTemplateName, DWORD dwAttrs, HRESULT hrNew, IShellItem *psiNewItem
) {
    (void)This; (void)dwFlags; (void)psiDest; (void)pszNewName; (void)pszTemplateName; (void)dwAttrs; (void)hrNew; (void)psiNewItem;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_UpdateProgress(IFileOperationProgressSink *This, UINT iWorkTotal, UINT iWorkSoFar) {
    (void)This; (void)iWorkTotal; (void)iWorkSoFar;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_ResetTimer(IFileOperationProgressSink *This) {
    (void)This;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_PauseTimer(IFileOperationProgressSink *This) {
    (void)This;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE sink_ResumeTimer(IFileOperationProgressSink *This) {
    (void)This;
    return S_OK;
}

static const IFileOperationProgressSinkVtbl g_sink_vtbl = {
    sink_QueryInterface,
    sink_AddRef,
    sink_Release,
    sink_StartOperations,
    sink_FinishOperations,
    sink_PreRenameItem,
    sink_PostRenameItem,
    sink_PreMoveItem,
    sink_PostMoveItem,
    sink_PreCopyItem,
    sink_PostCopyItem,
    sink_PreDeleteItem,
    sink_PostDeleteItem,
    sink_PreNewItem,
    sink_PostNewItem,
    sink_UpdateProgress,
    sink_ResetTimer,
    sink_PauseTimer,
    sink_ResumeTimer
};

int32_t aicl_windows_move_to_trash(
    const char *utf8_path,
    char *out_dest_buf,
    size_t out_dest_cap,
    char *out_err_buf,
    size_t out_err_cap
) {
    if (out_dest_buf && out_dest_cap > 0) out_dest_buf[0] = '\0';
    if (out_err_buf && out_err_cap > 0) out_err_buf[0] = '\0';

    wchar_t *wpath = utf8_to_wide_path(utf8_path, false, true);
    if (!wpath) {
        copy_cstr("invalid path", out_err_buf, out_err_cap);
        return AICL_TRASH_FAILED;
    }

    /* 1. Reject UNC network paths immediately */
    if (wpath[0] == L'\\' && wpath[1] == L'\\') {
        free(wpath);
        copy_cstr("network UNC paths do not support Windows Recycle Bin", out_err_buf, out_err_cap);
        return AICL_TRASH_UNAVAILABLE;
    }

    /* 2. Pre-flight drive type & Recycle Bin availability check */
    wchar_t vol_root[MAX_PATH];
    if (!GetVolumePathNameW(wpath, vol_root, (DWORD)_countof(vol_root))) {
        free(wpath);
        copy_cstr("unable to determine volume root for Recycle Bin check", out_err_buf, out_err_cap);
        return AICL_TRASH_UNAVAILABLE;
    }

    UINT drive_type = GetDriveTypeW(vol_root);
    if (drive_type != DRIVE_FIXED) {
        free(wpath);
        copy_cstr("non-fixed drive does not support safe Recycle Bin move", out_err_buf, out_err_cap);
        return AICL_TRASH_UNAVAILABLE;
    }

    SHQUERYRBINFO rb_info;
    memset(&rb_info, 0, sizeof(rb_info));
    rb_info.cbSize = sizeof(rb_info);
    HRESULT hr_rb = SHQueryRecycleBinW(vol_root, &rb_info);
    if (FAILED(hr_rb)) {
        free(wpath);
        copy_cstr("Recycle Bin is unavailable on this volume", out_err_buf, out_err_cap);
        return AICL_TRASH_UNAVAILABLE;
    }

    /* 3. Execute COM IFileOperation with recycle-only flags + PreDeleteItem abort guard */
    HRESULT hr_co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    bool should_uninit = (hr_co == S_OK || hr_co == S_FALSE);
    if (FAILED(hr_co) && hr_co != RPC_E_CHANGED_MODE) {
        free(wpath);
        copy_cstr("COM initialization failed", out_err_buf, out_err_cap);
        return AICL_TRASH_FAILED;
    }

    IFileOperation *op = NULL;
    IShellItem *item = NULL;
    DWORD cookie = 0;
    bool advised = false;
    int32_t status = AICL_TRASH_FAILED;

    aicl_trash_sink_t sink;
    memset(&sink, 0, sizeof(sink));
    sink.lpVtbl = &g_sink_vtbl;
    sink.ref_count = 1;

    HRESULT hr = CoCreateInstance(&CLSID_FileOperation, NULL, CLSCTX_ALL, &IID_IFileOperation, (void **)&op);
    if (FAILED(hr) || !op) {
        copy_cstr("CoCreateInstance(CLSID_FileOperation) failed", out_err_buf, out_err_cap);
        goto cleanup;
    }

    DWORD op_flags = FOFX_RECYCLEONDELETE | FOF_ALLOWUNDO | FOF_NOERRORUI | FOF_SILENT | FOFX_EARLYFAILURE;
    hr = IFileOperation_SetOperationFlags(op, op_flags);
    if (FAILED(hr)) {
        copy_cstr("IFileOperation::SetOperationFlags failed", out_err_buf, out_err_cap);
        goto cleanup;
    }

    hr = IFileOperation_Advise(op, (IFileOperationProgressSink *)&sink, &cookie);
    if (FAILED(hr)) {
        copy_cstr("IFileOperation::Advise failed", out_err_buf, out_err_cap);
        goto cleanup;
    }
    advised = true;

    hr = SHCreateItemFromParsingName(wpath, NULL, &IID_IShellItem, (void **)&item);
    if (FAILED(hr) || !item) {
        copy_cstr("SHCreateItemFromParsingName failed", out_err_buf, out_err_cap);
        goto cleanup;
    }

    hr = IFileOperation_DeleteItem(op, item, NULL);
    if (FAILED(hr)) {
        copy_cstr("IFileOperation::DeleteItem failed", out_err_buf, out_err_cap);
        goto cleanup;
    }

    hr = IFileOperation_PerformOperations(op);

    BOOL aborted = FALSE;
    (void)IFileOperation_GetAnyOperationsAborted(op, &aborted);

    if (sink.rejected_non_recycle
        || hr == AICL_HR_RECYCLE_SIZE_TOO_BIG
        || hr == AICL_HR_RECYCLE_FORCE_NUKE
        || hr == AICL_HR_RECYCLE_BIN_NOT_FOUND) {
        copy_cstr("Recycle Bin refused safe recycle; operation aborted without permanent deletion", out_err_buf, out_err_cap);
        status = AICL_TRASH_UNAVAILABLE;
        goto cleanup;
    }

    if (FAILED(hr) || aborted || !sink.recycled) {
        char msg[128];
        snprintf(msg, sizeof(msg), "IFileOperation failed (hr=0x%08lx, aborted=%d)", (unsigned long)hr, (int)aborted);
        copy_cstr(msg, out_err_buf, out_err_cap);
        status = AICL_TRASH_FAILED;
        goto cleanup;
    }

    if (sink.dest_path[0] != L'\0' && out_dest_buf && out_dest_cap > 0) {
        (void)wide_to_utf8_buf(sink.dest_path, out_dest_buf, out_dest_cap);
    }
    status = AICL_TRASH_OK;

cleanup:
    if (advised && op) {
        (void)IFileOperation_Unadvise(op, cookie);
    }
    if (item) {
        IShellItem_Release(item);
    }
    if (op) {
        IFileOperation_Release(op);
    }
    if (should_uninit) {
        CoUninitialize();
    }
    free(wpath);
    return status;
}

typedef struct {
    ULONG  ReparseTag;
    USHORT ReparseDataLength;
    USHORT Reserved;
    USHORT SubstituteNameOffset;
    USHORT SubstituteNameLength;
    USHORT PrintNameOffset;
    USHORT PrintNameLength;
    WCHAR  PathBuffer[1];
} aicl_mount_point_reparse_t;

bool aicl_windows_create_junction(const char *utf8_link_path, const char *utf8_target_path) {
    wchar_t *wlink = utf8_to_wide_path(utf8_link_path, false, true);
    wchar_t *wtarget = utf8_to_wide_path(utf8_target_path, false, true);
    if (!wlink || !wtarget) {
        free(wlink);
        free(wtarget);
        return false;
    }

    if (!CreateDirectoryW(wlink, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
        free(wlink);
        free(wtarget);
        return false;
    }

    HANDLE h = CreateFileW(
        wlink,
        GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL
    );
    free(wlink);
    if (h == INVALID_HANDLE_VALUE) {
        free(wtarget);
        return false;
    }

    size_t target_chars = wcslen(wtarget);
    size_t subst_chars = target_chars + 4; /* "\??\" + target */
    size_t subst_bytes = subst_chars * sizeof(wchar_t);
    size_t print_bytes = target_chars * sizeof(wchar_t);
    size_t data_len = 8 + subst_bytes + sizeof(wchar_t) + print_bytes + sizeof(wchar_t);
    size_t total_len = 8 + data_len;

    aicl_mount_point_reparse_t *buf = (aicl_mount_point_reparse_t *)calloc(1, total_len + 16);
    if (!buf) {
        CloseHandle(h);
        free(wtarget);
        return false;
    }

    buf->ReparseTag = IO_REPARSE_TAG_MOUNT_POINT;
    buf->ReparseDataLength = (USHORT)data_len;
    buf->Reserved = 0;
    buf->SubstituteNameOffset = 0;
    buf->SubstituteNameLength = (USHORT)subst_bytes;
    buf->PrintNameOffset = (USHORT)(subst_bytes + sizeof(wchar_t));
    buf->PrintNameLength = (USHORT)print_bytes;

    wcscpy(buf->PathBuffer, L"\\??\\");
    wcscpy(buf->PathBuffer + 4, wtarget);
    buf->PathBuffer[subst_chars] = L'\0';
    wcscpy(buf->PathBuffer + subst_chars + 1, wtarget);
    buf->PathBuffer[subst_chars + 1 + target_chars] = L'\0';

    DWORD returned = 0;
    BOOL ok = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, buf, (DWORD)total_len, NULL, 0, &returned, NULL);
    free(buf);
    free(wtarget);
    CloseHandle(h);
    return ok != 0;
}

int32_t aicl_windows_lock_file_exclusive(const char *utf8_path, void **out_handle) {
    if (!utf8_path || !out_handle) return ERROR_INVALID_PARAMETER;
    *out_handle = NULL;
    wchar_t *wpath = utf8_to_wide_path(utf8_path, true, false);
    if (!wpath) return ERROR_INVALID_PARAMETER;

    HANDLE h = CreateFileW(
        wpath,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        return (int32_t)GetLastError();
    }
    *out_handle = (void *)h;
    return 0;
}

void aicl_windows_unlock_file(void *handle) {
    if (handle) {
        CloseHandle((HANDLE)handle);
    }
}

#endif
