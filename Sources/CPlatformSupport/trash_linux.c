#if defined(__linux__)
#define _GNU_SOURCE
#include "CPlatformSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// Linux renameat2 ABI value for SDKs that do not ship the kernel UAPI headers.
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

static int open_private_directory(int parent, const char *name) {
    if (mkdirat(parent, name, 0700) != 0 && errno != EEXIST) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_uid != geteuid() || (st.st_mode & 0077) != 0) {
        close(fd);
        errno = EACCES;
        return -1;
    }
    return fd;
}

int32_t aicl_linux_trash_move(const char *source, const char *trash_root, const char *name,
                             const uint8_t *metadata, size_t length) {
    if (!source || !trash_root || !name || !metadata || strchr(name, '/') || name[0] == '.') return EINVAL;

    char info_name[256];
    int name_length = snprintf(info_name, sizeof(info_name), "%s.trashinfo", name);
    if (name_length < 0 || (size_t)name_length >= sizeof(info_name)) return ENAMETOOLONG;

    int root = open_private_directory(AT_FDCWD, trash_root);
    if (root < 0) return errno;
    int files = -1, info = -1, metadata_fd = -1;
    int error = 0;

    files = open_private_directory(root, "files");
    if (files < 0) { error = errno; goto done; }
    info = open_private_directory(root, "info");
    if (info < 0) { error = errno; goto done; }
    metadata_fd = openat(info, info_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (metadata_fd < 0) { error = errno; goto done; }

    size_t written = 0;
    while (written < length) {
        ssize_t count = write(metadata_fd, metadata + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { error = count < 0 ? errno : EIO; goto rollback; }
        written += (size_t)count;
    }
    if (fsync(metadata_fd) != 0) { error = errno; goto rollback; }

    // RENAME_NOREPLACE keeps existing trash payloads intact. EXDEV keeps the source intact.
    // Filesystems without atomic no-replace rename are ineligible for trashing.
    if (syscall(SYS_renameat2, AT_FDCWD, source, files, name, RENAME_NOREPLACE) == 0) goto done;
    error = errno;

rollback:
    // Only roll back the metadata file created above with O_EXCL, never the source or a payload.
    (void)unlinkat(info, info_name, 0);
done:
    if (metadata_fd >= 0) close(metadata_fd);
    if (info >= 0) close(info);
    if (files >= 0) close(files);
    close(root);
    return error;
}
#endif
