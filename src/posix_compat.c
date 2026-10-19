#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
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
int pm_spawn(const char *exe, char *const *argv, int *parent_fd) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
        return -1;
    int parent = fcntl(pair[0], F_DUPFD_CLOEXEC, 4), child = fcntl(pair[1], F_DUPFD_CLOEXEC, 4);
    close(pair[0]);
    close(pair[1]);
    if (parent < 0 || child < 0) {
        if (parent >= 0)
            close(parent);
        if (child >= 0)
            close(child);
        return -1;
    }
    int toclose[1024];
    size_t count = 0;
    DIR *directory = opendir("/proc/self/fd");
    if (directory) {
        struct dirent *entry;
        while ((entry = readdir(directory)) && count < 1024) {
            int fd = atoi(entry->d_name);
            if (fd > 3)
                toclose[count++] = fd;
        }
        closedir(directory);
    }
    pid_t owner = getpid(), pid = fork();
    if (pid == 0) {
        close(parent);
#ifdef __linux__
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner)
            _exit(127);
#endif
        if (dup2(child, 3) < 0)
            _exit(127);
        close(child);
        if (fcntl(3, F_SETFD, 0) < 0)
            _exit(127);
        for (size_t i = 0; i < count; i++)
            close(toclose[i]);
        /* No setsid/setpgrp: remain a child of the InkView task's group. */
        execv(exe, argv);
        _exit(127);
    }
    close(child);
    if (pid < 0) {
        close(parent);
        return -1;
    }
    *parent_fd = parent;
    return pid;
}
int pm_poll(int fd, int ms) {
    struct pollfd p = {fd, POLLIN, 0};
    int n;
    do {
        n = poll(&p, 1, ms);
    } while (n < 0 && errno == EINTR);
    return n;
}
ssize_t pm_send(int fd, const void *buf, size_t n) {
#ifdef MSG_NOSIGNAL
    return send(fd, buf, n, MSG_NOSIGNAL);
#else
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
    return send(fd, buf, n, 0);
#endif
}
ssize_t pm_recv(int fd, void *buf, size_t n) { return recv(fd, buf, n, 0); }
void pm_interrupt(int pid, int fd) {
    if (fd >= 0)
        shutdown(fd, SHUT_RDWR);
    if (pid > 0) {
        int status;
        pid_t n;
        do {
            n = waitpid(pid, &status, WNOHANG);
        } while (n < 0 && errno == EINTR);
        if (n == 0)
            kill(pid, SIGKILL);
    }
}
int pm_reap(int pid, int block) {
    int status = 0;
    pid_t n;
    do {
        n = waitpid(pid, &status, block ? 0 : WNOHANG);
    } while (n < 0 && errno == EINTR);
    return n == pid || (n < 0 && errno == ECHILD);
}

uint64_t pm_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
size_t pm_rss_kib(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f)
        return 0;
    char line[256];
    unsigned long n = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "VmRSS: %lu kB", &n) == 1)
            break;
    }
    fclose(f);
    return n;
}
void pm_eof(int fd) { shutdown(fd, SHUT_WR); }
