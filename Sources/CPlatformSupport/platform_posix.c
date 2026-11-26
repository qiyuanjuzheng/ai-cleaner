#if defined(__APPLE__) || defined(__linux__)

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "CPlatformSupport.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#if defined(__linux__)
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#if defined(SYS_statx) && defined(__has_include)
#if __has_include(<linux/stat.h>)
#include <linux/stat.h>
#define AICL_HAVE_LINUX_STATX 1
#endif
#endif
#endif

static int32_t posix_mode_to_kind(mode_t mode) {
    switch (mode & S_IFMT) {
        case S_IFREG:  return AICL_FILE_KIND_REGULAR;
        case S_IFDIR:  return AICL_FILE_KIND_DIRECTORY;
        case S_IFLNK:  return AICL_FILE_KIND_SYMLINK;
        case S_IFIFO:  return AICL_FILE_KIND_FIFO;
        case S_IFSOCK: return AICL_FILE_KIND_SOCKET;
        case S_IFCHR:
        case S_IFBLK:  return AICL_FILE_KIND_DEVICE;
        default:       return AICL_FILE_KIND_OTHER;
    }
}

static int32_t copy_str(const char *src, char *dst, size_t cap) {
    if (!src || !dst || cap == 0) return -1;
    size_t len = strlen(src);
    if (len >= cap) return -1;
    memcpy(dst, src, len + 1);
    return (int32_t)len;
}

int32_t aicl_file_identity(const char *utf8_path, aicl_file_identity_t *out) {
    if (!utf8_path || !out) return EINVAL;
    memset(out, 0, sizeof(*out));

#if defined(AICL_HAVE_LINUX_STATX)
    struct statx stx;
    memset(&stx, 0, sizeof(stx));
    long ret = syscall(
        SYS_statx,
        AT_FDCWD,
        utf8_path,
        AT_SYMLINK_NOFOLLOW,
        STATX_BASIC_STATS | STATX_BTIME,
        &stx
    );
    if (ret == 0) {
        out->kind = posix_mode_to_kind((mode_t)stx.stx_mode);
        out->has_uid = true;
        out->uid = (uint32_t)stx.stx_uid;
        out->volume_id = (uint64_t)makedev(stx.stx_dev_major, stx.stx_dev_minor);
        out->file_id_low = (uint64_t)stx.stx_ino;
        out->file_id_high = 0;
        out->size = (int64_t)stx.stx_size;
        out->modified_sec = (int64_t)stx.stx_mtime.tv_sec;
        out->modified_nsec = (int32_t)stx.stx_mtime.tv_nsec;
        out->has_changed = true;
        out->changed_sec = (int64_t)stx.stx_ctime.tv_sec;
        out->changed_nsec = (int32_t)stx.stx_ctime.tv_nsec;
        if ((stx.stx_mask & STATX_BTIME) != 0) {
            out->has_created = true;
            out->created_sec = (int64_t)stx.stx_btime.tv_sec;
            out->created_nsec = (int32_t)stx.stx_btime.tv_nsec;
        }
        out->is_hidden_or_system = false;
        out->error_code = 0;
        return 0;
    }
    if (errno != ENOSYS && errno != EPERM && errno != EINVAL) {
        out->error_code = errno;
        return errno;
    }
#endif

    struct stat st;
    if (lstat(utf8_path, &st) != 0) {
        int err = errno;
        out->error_code = err;
        return err;
    }

    out->kind = posix_mode_to_kind(st.st_mode);
    out->has_uid = true;
    out->uid = (uint32_t)st.st_uid;
    out->volume_id = (uint64_t)st.st_dev;
    out->file_id_low = (uint64_t)st.st_ino;
    out->file_id_high = 0;
    out->size = (int64_t)st.st_size;
#if defined(__APPLE__)
    out->modified_sec = (int64_t)st.st_mtimespec.tv_sec;
    out->modified_nsec = (int32_t)st.st_mtimespec.tv_nsec;
    out->has_changed = true;
    out->changed_sec = (int64_t)st.st_ctimespec.tv_sec;
    out->changed_nsec = (int32_t)st.st_ctimespec.tv_nsec;
    out->has_created = true;
    out->created_sec = (int64_t)st.st_birthtimespec.tv_sec;
    out->created_nsec = (int32_t)st.st_birthtimespec.tv_nsec;
#else
    out->modified_sec = (int64_t)st.st_mtim.tv_sec;
    out->modified_nsec = (int32_t)st.st_mtim.tv_nsec;
    out->has_changed = true;
    out->changed_sec = (int64_t)st.st_ctim.tv_sec;
    out->changed_nsec = (int32_t)st.st_ctim.tv_nsec;
    out->has_created = false;
#endif
    out->is_hidden_or_system = false;
    out->error_code = 0;
    return 0;
}

int32_t aicl_current_principal(uint32_t *out_uid, char *out_sid, size_t sid_cap) {
    (void)out_sid;
    (void)sid_cap;
    if (!out_uid) return 0;
    *out_uid = (uint32_t)getuid();
    return 1;
}

aicl_disk_capacity_t aicl_disk_capacity(const char *utf8_path) {
    aicl_disk_capacity_t result = {0, 0, false};
    if (!utf8_path) return result;

    struct statvfs vfs;
    if (statvfs(utf8_path, &vfs) != 0) {
        return result;
    }

    unsigned long long unit = vfs.f_frsize > 0 ? (unsigned long long)vfs.f_frsize : (unsigned long long)vfs.f_bsize;
    unsigned long long total = (unsigned long long)vfs.f_blocks * unit;
    unsigned long long avail = (unsigned long long)vfs.f_bavail * unit;
    if (total > (unsigned long long)INT64_MAX) total = (unsigned long long)INT64_MAX;
    if (avail > (unsigned long long)INT64_MAX) avail = (unsigned long long)INT64_MAX;

    result.total_bytes = (int64_t)total;
    result.available_bytes = (int64_t)avail;
    result.ok = true;
    return result;
}

bool aicl_has_active_file_lock(const char *utf8_path) {
    if (!utf8_path) return false;
    int fd = open(utf8_path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0) return false;

    struct flock fl;
    memset(&fl, 0, sizeof(fl));
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;
    if (fcntl(fd, F_GETLK, &fl) == 0 && fl.l_type != F_UNLCK) {
        close(fd);
        return true;
    }

    if (flock(fd, LOCK_SH | LOCK_NB) != 0) {
        int err = errno;
        close(fd);
        return err == EWOULDBLOCK || err == EAGAIN;
    }
    (void)flock(fd, LOCK_UN);
    close(fd);
    return false;
}

int32_t aicl_resolve_real_path(const char *utf8_path, char *out_buf, size_t out_cap) {
    if (!utf8_path || !out_buf || out_cap == 0) return -1;
    char *resolved = realpath(utf8_path, NULL);
    if (!resolved) return -1;
    int32_t len = copy_str(resolved, out_buf, out_cap);
    free(resolved);
    return len;
}

int32_t aicl_get_env(const char *utf8_name, char *out_buf, size_t out_cap) {
    if (!utf8_name || !out_buf || out_cap == 0) return -1;
    const char *val = getenv(utf8_name);
    if (!val) return -1;
    return copy_str(val, out_buf, out_cap);
}

int32_t aicl_get_known_path(int32_t kind, char *out_buf, size_t out_cap) {
    if (!out_buf || out_cap == 0) return -1;
    switch (kind) {
        case AICL_KNOWN_PATH_HOME: {
            const char *home = getenv("HOME");
            if (home && home[0] != '\0') {
                return copy_str(home, out_buf, out_cap);
            }
            struct passwd pwd;
            struct passwd *result = NULL;
            char pwbuf[4096];
            if (getpwuid_r(getuid(), &pwd, pwbuf, sizeof(pwbuf), &result) == 0 && result && result->pw_dir) {
                return copy_str(result->pw_dir, out_buf, out_cap);
            }
            return -1;
        }
        case AICL_KNOWN_PATH_USER_TEMP: {
#if defined(__APPLE__)
            char buf[PATH_MAX];
            size_t len = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, sizeof(buf));
            if (len > 0 && len <= sizeof(buf) && buf[0] != '\0') {
                return copy_str(buf, out_buf, out_cap);
            }
#endif
            const char *tmpdir = getenv("TMPDIR");
            if (tmpdir && tmpdir[0] == '/') {
                return copy_str(tmpdir, out_buf, out_cap);
            }
            return copy_str("/tmp", out_buf, out_cap);
        }
        case AICL_KNOWN_PATH_EXECUTABLE: {
#if defined(__APPLE__)
            uint32_t size = (uint32_t)(out_cap > UINT32_MAX ? UINT32_MAX : out_cap);
            if (_NSGetExecutablePath(out_buf, &size) == 0) {
                return (int32_t)strlen(out_buf);
            }
            return -1;
#else
            ssize_t n = readlink("/proc/self/exe", out_buf, out_cap - 1);
            if (n > 0) {
                out_buf[n] = '\0';
                return (int32_t)n;
            }
            return -1;
#endif
        }
        default:
            return -1;
    }
}

struct aicl_ro_file {
    int fd;
};

aicl_ro_file_t *aicl_ro_file_open(const char *utf8_path) {
    if (!utf8_path) return NULL;
    int fd = open(utf8_path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }

    aicl_ro_file_t *handle = (aicl_ro_file_t *)malloc(sizeof(aicl_ro_file_t));
    if (!handle) {
        close(fd);
        return NULL;
    }
    handle->fd = fd;
    return handle;
}

int64_t aicl_ro_file_read(aicl_ro_file_t *file, uint8_t *buf, size_t count) {
    if (!file || !buf || count == 0) return 0;
    size_t total = 0;
    while (total < count) {
        ssize_t n = read(file->fd, buf + total, count - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return total > 0 ? (int64_t)total : -1;
        }
        if (n == 0) break;
        total += (size_t)n;
    }
    return (int64_t)total;
}

int64_t aicl_ro_file_size(aicl_ro_file_t *file) {
    if (!file) return -1;
    struct stat st;
    if (fstat(file->fd, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

bool aicl_ro_file_seek(aicl_ro_file_t *file, uint64_t offset) {
    if (!file) return false;
    return lseek(file->fd, (off_t)offset, SEEK_SET) != (off_t)-1;
}

void aicl_ro_file_close(aicl_ro_file_t *file) {
    if (!file) return;
    close(file->fd);
    free(file);
}

bool aicl_list_directory(const char *utf8_path, aicl_dir_entry_cb cb, void *ctx) {
    if (!utf8_path || !cb) return false;
    int fd = open(utf8_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    DIR *dir = fdopendir(fd);
    if (!dir) {
        close(fd);
        return false;
    }

    bool complete = false;
    while (true) {
        errno = 0;
        const struct dirent *entry = readdir(dir);
        if (!entry) {
            complete = errno == 0;
            break;
        }
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        if (!cb(name, ctx)) break;
    }
    closedir(dir);
    return complete;
}

bool aicl_posix_is_sticky_trash_dir(const char *utf8_path) {
    if (!utf8_path) return false;
    struct stat st;
    if (lstat(utf8_path, &st) != 0) return false;
    if (!S_ISDIR(st.st_mode)) return false;
    return (st.st_mode & S_ISVTX) != 0;
}

int32_t aicl_volume_case_sensitive(const char *utf8_path) {
    if (!utf8_path) return -1;
#if defined(__APPLE__) && defined(_PC_CASE_SENSITIVE)
    long val = pathconf(utf8_path, _PC_CASE_SENSITIVE);
    if (val == 1) return 1;
    if (val == 0) return 0;
    return -1;
#else
    return 1;
#endif
}

#endif
