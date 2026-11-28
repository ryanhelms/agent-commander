//go:build darwin && cgo

package main

/*
#include <errno.h>
#include <libproc.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
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
