#include "LibprocBridge.h"
#include <errno.h>
#include <stddef.h>
#include <string.h>

int CPReadResources(pid_t pid, struct rusage_info_v0 *usage, uint64_t *cpuEnergyNJ) {
    *cpuEnergyNJ = UINT64_MAX;
#if defined(__arm64__) && defined(RUSAGE_INFO_V6)
    // The SDK resource flavors share a prefix. Preserve the caller's sentinels.
    _Static_assert(offsetof(struct rusage_info_v6, ri_child_user_time) == sizeof(struct rusage_info_v0),
                   "Unexpected rusage prefix");
    struct rusage_info_v6 extended = { .ri_energy_nj = UINT64_MAX };
    memcpy(&extended, usage, sizeof(*usage));
    int result = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&extended);
    if (result == 0) {
        memcpy(usage, &extended, sizeof(*usage));
        *cpuEnergyNJ = extended.ri_energy_nj;
        return 0;
    }
    if (result != -1 || (errno != EINVAL && errno != ENOTSUP)) {
        return result;
    }
    errno = 0;
#endif
    return proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)usage);
}
