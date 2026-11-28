//go:build darwin && cgo

package main

/*
#include <errno.h>
#include <libproc.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int selfProcess(int pid, uint64_t *seconds, uint64_t *micros, char *path) {
	struct proc_bsdinfo before, after;
	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) {
		return errno ? errno : EIO;
	}
	if (before.pbi_status == SZOMB) {
		return ESRCH;
	}
	if (before.pbi_uid != geteuid() || before.pbi_ruid != getuid()) {
		return EPERM;
	}
	if (proc_pidpath(pid, path, PROC_PIDPATHINFO_MAXSIZE) <= 0) {
		return errno ? errno : EIO;
	}
	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after)) {
		return errno ? errno : EIO;
	}
	if (before.pbi_start_tvsec != after.pbi_start_tvsec ||
		before.pbi_start_tvusec != after.pbi_start_tvusec ||
		before.pbi_uid != after.pbi_uid || before.pbi_ruid != after.pbi_ruid ||
		after.pbi_status == SZOMB) {
		return ESRCH;
	}
	*seconds = before.pbi_start_tvsec;
	*micros = before.pbi_start_tvusec;
	return 0;
}

// KERN_PROCARGS2 returns argc, the executable path, NUL padding, and argv.
// Inspect only the arguments. The same buffer may also include the environment.
static int serveRole(int pid, int *result) {
	int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
	size_t size;
	if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) {
		return errno;
	}
	if (size < sizeof(int)) {
		return EINVAL;
	}
	char *args = malloc(size);
	if (args == NULL) {
		return ENOMEM;
	}
	int error = 0;
	*result = 0;
	if (sysctl(mib, 3, args, &size, NULL, 0) < 0) {
		error = errno;
		goto done;
	}
	if (size < sizeof(int)) {
		error = EINVAL;
		goto done;
	}
	int argc;
	memcpy(&argc, args, sizeof(argc));
	if (argc == 2) {
		char *end = args + size;
		char *arg = memchr(args + sizeof(argc), 0, size - sizeof(argc));
		if (arg != NULL) {
			while (arg < end && *arg == 0) {
				arg++;
			}
			arg = memchr(arg, 0, end - arg);
			if (arg != NULL && end - arg > sizeof("serve") &&
				memcmp(arg + 1, "serve", sizeof("serve")) == 0) {
				*result = 1;
			}
		}
	}
done:
	free(args);
	return error;
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

func listeningProcesses(ctx context.Context, socket string) ([]int, error) {
	scan, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(scan, "/usr/sbin/lsof",
		"-nP", "-a", "-U", "-u", strconv.Itoa(os.Geteuid()), "-F0pn").Output()
	if scan.Err() != nil {
		return nil, fmt.Errorf("inspect the owner of %s: %w", socket, scan.Err())
	}
	var exited *exec.ExitError
	if err != nil && (!errors.As(err, &exited) || exited.ExitCode() != 1 || len(exited.Stderr) != 0 || len(raw) != 0) {
		return nil, fmt.Errorf("list Unix sockets for the owner: %w", err)
	}
	canonical := socket
	if parent, err := filepath.EvalSymlinks(filepath.Dir(socket)); err == nil {
		canonical = filepath.Join(parent, filepath.Base(socket))
	}
	return socketPIDs(raw, socket, canonical)
}

func inspectProcess(pid int) (*process, error) {
	var seconds, micros C.uint64_t
	var path [C.PROC_PIDPATHINFO_MAXSIZE]C.char
	status := syscall.Errno(C.selfProcess(C.int(pid), &seconds, &micros, &path[0]))
	switch status {
	case syscall.ESRCH, syscall.ENOENT:
		return nil, nil
	case 0:
		return &process{
			pid:     pid,
			path:    C.GoString(&path[0]),
			started: time.Unix(int64(seconds), int64(micros)*int64(time.Microsecond)),
		}, nil
	default:
		return nil, fmt.Errorf("inspect PID %d: %w", pid, status)
	}
}

func ownsServeArguments(pid int) (bool, error) {
	var result C.int
	if status := syscall.Errno(C.serveRole(C.int(pid), &result)); status != 0 {
		return false, fmt.Errorf("inspect the service arguments for PID %d: %w", pid, status)
	}
	return result != 0, nil
}
