// Local fixtures for full CPU saturation or a single process with a duty cycle.
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

static void burn_at_duty(long seconds, long duty) {
    const uint64_t period = UINT64_C(100000000);
    const uint64_t busy = period * (uint64_t)duty / 100;
    const uint64_t start = uptime_ns();
    const uint64_t deadline = start + (uint64_t)seconds * UINT64_C(1000000000);
    printf("%d\n", getpid());
    fflush(stdout);
    for (uint64_t cycle = start; cycle < deadline; cycle += period) {
        uint64_t stop = cycle + busy;
        burn(&stop);
        const uint64_t now = uptime_ns();
        const uint64_t next = cycle + period;
        if (now < next) {
            struct timespec remaining = { .tv_nsec = (long)(next - now) };
            while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
        }
    }
}

int main(int argc, char **argv) {
    char *end = NULL;
    errno = 0;
    long seconds = (argc == 2 || argc == 3) ? strtol(argv[1], &end, 10) : 0;
    if (errno || !end || *end || seconds < 1 || seconds > 60) {
        fprintf(stderr, "Usage: cpu-load SECONDS (1–60) [DUTY_PERCENT (1–99)]\n");
        return 64;
    }
    if (argc == 3) {
        errno = 0;
        const long duty = strtol(argv[2], &end, 10);
        if (errno || *end || duty < 1 || duty > 99) {
            fprintf(stderr, "DUTY_PERCENT must be between 1 and 99.\n");
            return 64;
        }
        burn_at_duty(seconds, duty);
        return 0;
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
