// Local fixture. One process runs two busy threads and owns an idle helper.
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t uptime_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void *burn(void *argument) {
    const uint64_t deadline = *(const uint64_t *)argument;
    volatile uint64_t work = 1;
    while (uptime_ns() < deadline) {
        for (unsigned int i = 0; i < 4096; i++) {
            work = work * UINT64_C(6364136223846793005) + 1;
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    char *end = NULL;
    errno = 0;
    long seconds = argc == 2 ? strtol(argv[1], &end, 10) : 0;
    if (errno || !end || *end || seconds < 1 || seconds > 60) {
        fprintf(stderr, "Usage: cpu-load SECONDS (1–60)\n");
        return 64;
    }

    const pid_t helper = fork();
    if (helper < 0) {
        perror("fork");
        return 1;
    }
    if (helper == 0) {
        struct timespec remaining = { .tv_sec = seconds };
        while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
        _exit(0);
    }
    printf("%d %d\n", getpid(), helper);
    fflush(stdout);

    const uint64_t deadline = uptime_ns() + (uint64_t)seconds * UINT64_C(1000000000);
    pthread_t worker;
    const int started = pthread_create(&worker, NULL, burn, (void *)&deadline);
    if (started != 0) {
        fprintf(stderr, "pthread_create failed (%d)\n", started);
    } else {
        burn((void *)&deadline);
        pthread_join(worker, NULL);
    }
    int status;
    while (waitpid(helper, &status, 0) < 0 && errno == EINTR) {}
    return started == 0 ? 0 : 1;
}
