#ifndef AICLEANER_CPLATFORM_SUPPORT_H
#define AICLEANER_CPLATFORM_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AICL_FILE_KIND_REGULAR = 0,
    AICL_FILE_KIND_DIRECTORY = 1,
    AICL_FILE_KIND_SYMLINK = 2,
    AICL_FILE_KIND_REPARSE_POINT = 3,
    AICL_FILE_KIND_FIFO = 4,
    AICL_FILE_KIND_SOCKET = 5,
    AICL_FILE_KIND_DEVICE = 6,
    AICL_FILE_KIND_OTHER = 7
};

enum {
    AICL_TRASH_OK = 0,
    AICL_TRASH_UNAVAILABLE = 1,
    AICL_TRASH_FAILED = 2
};

enum {
    AICL_KNOWN_PATH_HOME = 0,
    AICL_KNOWN_PATH_USER_TEMP = 1,
    AICL_KNOWN_PATH_WIN_ROAMING_APPDATA = 2,
    AICL_KNOWN_PATH_WIN_LOCAL_APPDATA = 3,
    AICL_KNOWN_PATH_EXECUTABLE = 4
};

typedef struct {
    int32_t kind;
    uint32_t reparse_tag;
    bool has_uid;
    uint32_t uid;
    bool has_sid;
    char sid[128];
    uint64_t volume_id;
    uint64_t file_id_low;
    uint64_t file_id_high;
    int64_t size;
    int64_t modified_sec;
    int32_t modified_nsec;
    bool has_changed;
    int64_t changed_sec;
    int32_t changed_nsec;
    bool has_created;
    int64_t created_sec;
    int32_t created_nsec;
    bool is_hidden_or_system;
    int32_t error_code;
} aicl_file_identity_t;

typedef struct {
    int64_t total_bytes;
    int64_t available_bytes;
    bool ok;
} aicl_disk_capacity_t;

typedef struct aicl_ro_file aicl_ro_file_t;
typedef bool (*aicl_dir_entry_cb)(const char *utf8_name, void *ctx);

int32_t aicl_file_identity(const char *utf8_path, aicl_file_identity_t *out_identity);
int32_t aicl_current_principal(uint32_t *out_uid, char *out_sid, size_t sid_cap);
aicl_disk_capacity_t aicl_disk_capacity(const char *utf8_path);
bool aicl_has_active_file_lock(const char *utf8_path);
int32_t aicl_resolve_real_path(const char *utf8_path, char *out_buf, size_t out_cap);
int32_t aicl_get_env(const char *utf8_name, char *out_buf, size_t out_cap);
int32_t aicl_get_known_path(int32_t kind, char *out_buf, size_t out_cap);

aicl_ro_file_t *aicl_ro_file_open(const char *utf8_path);
int64_t aicl_ro_file_read(aicl_ro_file_t *file, uint8_t *buf, size_t count);
int64_t aicl_ro_file_size(aicl_ro_file_t *file);
bool aicl_ro_file_seek(aicl_ro_file_t *file, uint64_t offset);
void aicl_ro_file_close(aicl_ro_file_t *file);

bool aicl_list_directory(const char *utf8_path, aicl_dir_entry_cb cb, void *ctx);

/* Keep the returned handle open to hold the exclusive lock. */
void *aicl_data_directory_lock(const char *utf8_path);
void aicl_data_directory_unlock(void *handle);

int32_t aicl_linux_trash_move(const char *source, const char *trash_root, const char *name,
                             const uint8_t *metadata, size_t length);
bool aicl_posix_is_sticky_trash_dir(const char *utf8_path);
int32_t aicl_volume_case_sensitive(const char *utf8_path);

int32_t aicl_windows_move_to_trash(
    const char *utf8_path,
    char *out_dest_buf,
    size_t out_dest_cap,
    char *out_err_buf,
    size_t out_err_cap
);

bool aicl_windows_create_junction(const char *utf8_link_path, const char *utf8_target_path);
int32_t aicl_windows_lock_file_exclusive(const char *utf8_path, void **out_handle);
void aicl_windows_unlock_file(void *handle);

#ifdef __cplusplus
}
#endif

#endif
