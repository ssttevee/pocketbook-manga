/* Kernel 3.10 I/O for device_io.zig: stat without statx, and entropy from
 * /dev/urandom where getrandom is missing. */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
struct pm_stat {
    uint64_t ino, nlink, size;
    int64_t atime_s, mtime_s, ctime_s;
    uint64_t atime_ns, mtime_ns, ctime_ns, block_size;
    uint32_t mode;
};
int pm_stat(int fd, const char *path, int nofollow, struct pm_stat *out) {
    struct stat st;
    int result;
    do {
        result = path ? fstatat(fd, path, &st, nofollow ? AT_SYMLINK_NOFOLLOW : 0) : fstat(fd, &st);
    } while (result && errno == EINTR);
    if (result)
        return errno;
    out->ino = st.st_ino;
    out->nlink = st.st_nlink;
    out->size = st.st_size;
    out->block_size = st.st_blksize;
    out->mode = st.st_mode;
#ifdef __APPLE__
    out->atime_s = st.st_atimespec.tv_sec;
    out->atime_ns = st.st_atimespec.tv_nsec;
    out->mtime_s = st.st_mtimespec.tv_sec;
    out->mtime_ns = st.st_mtimespec.tv_nsec;
    out->ctime_s = st.st_ctimespec.tv_sec;
    out->ctime_ns = st.st_ctimespec.tv_nsec;
#else
    out->atime_s = st.st_atim.tv_sec;
    out->atime_ns = st.st_atim.tv_nsec;
    out->mtime_s = st.st_mtim.tv_sec;
    out->mtime_ns = st.st_mtim.tv_nsec;
    out->ctime_s = st.st_ctim.tv_sec;
    out->ctime_ns = st.st_ctim.tv_nsec;
#endif
    return 0;
}
int pm_entropy(unsigned char *buf, size_t len) {
    int fd;
    do {
        fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0)
        return -1;
    struct stat st;
    if (fstat(fd, &st) || !S_ISCHR(st.st_mode)) {
        close(fd);
        return -1;
    }
    while (len) {
        ssize_t n = read(fd, buf, len);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            close(fd);
            return -1;
        }
        buf += n;
        len -= n;
    }
    close(fd);
    return 0;
}

#include <sys/statvfs.h>
int pm_storage_free(const char *path, uint64_t *available) {
    struct statvfs st;
    if (statvfs(path, &st)) return errno;
    *available = (uint64_t)st.f_bavail * st.f_frsize;
    return 0;
}

int pm_storage_capacity(const char *path, uint64_t *total, uint64_t *used) {
    struct statvfs st;
    if (statvfs(path, &st)) return errno;
    *total = (uint64_t)st.f_blocks * st.f_frsize;
    *used = (uint64_t)(st.f_blocks - st.f_bfree) * st.f_frsize;
    return 0;
}
