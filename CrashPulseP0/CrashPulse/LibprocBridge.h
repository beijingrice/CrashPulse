#ifndef CRASHPULSE_LIBPROC_BRIDGE_H
#define CRASHPULSE_LIBPROC_BRIDGE_H

#include <libproc.h>

enum { CPPathBufferSize = PROC_PIDPATHINFO_MAXSIZE };

int CPReadResources(pid_t pid, struct rusage_info_v0 *usage, uint64_t *cpuEnergyNJ);

#endif
