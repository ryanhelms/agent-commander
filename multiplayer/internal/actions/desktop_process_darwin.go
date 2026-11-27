//go:build darwin && cgo

package actions

/*
#cgo LDFLAGS: -framework CoreFoundation -framework Security
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <libproc.h>
#include <sys/proc_info.h>

static bool commanderAppCode(int pid) {
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
	if (number == NULL) {
		return false;
	}
	const void *keys[] = { kSecGuestAttributePid };
	const void *values[] = { number };
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(number);
	if (attributes == NULL) {
		return false;
	}
	SecCodeRef code = NULL;
	OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
	CFRelease(attributes);
	if (status != errSecSuccess || code == NULL) {
		return false;
	}
	SecRequirementRef requirement = NULL;
	status = SecRequirementCreateWithString(CFSTR("identifier \"local.agentcommander.cockpit\""),
		kSecCSDefaultFlags, &requirement);
	if (status == errSecSuccess && requirement != NULL) {
		status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
		CFRelease(requirement);
	} else {
		CFRelease(code);
		return false;
	}
	CFRelease(code);
	return status == errSecSuccess;
}
*/
import "C"

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

func desktopProcessHome() string {
	account, err := user.Current()
	if err != nil {
		return ""
	}
	return account.HomeDir
}

func desktopProcessMatches(record launchRecord) bool {
	executable, err := filepath.EvalSymlinks(record.Executable)
	if err != nil || !filepath.IsAbs(executable) || !strings.HasSuffix(executable, ".app/Contents/MacOS/AgentCommander") ||
		!desktopProcessStartMatches(record) {
		return false
	}
	var path [C.PROC_PIDPATHINFO_MAXSIZE]byte
	if C.proc_pidpath(C.int(record.PID), unsafe.Pointer(&path[0]), C.uint32_t(len(path))) <= 0 {
		return false
	}
	actual, err := filepath.EvalSymlinks(unix.ByteSliceToString(path[:]))
	return err == nil && actual == executable && bool(C.commanderAppCode(C.int(record.PID))) && desktopProcessStartMatches(record)
}

func desktopProcessStartMatches(record launchRecord) bool {
	proc, err := unix.SysctlKinfoProc("kern.proc.pid", record.PID)
	return err == nil && int(proc.Proc.P_pid) == record.PID && proc.Eproc.Ucred.Uid == uint32(os.Geteuid()) &&
		proc.Proc.P_starttime.Sec == record.StartedSeconds && int64(proc.Proc.P_starttime.Usec) == record.StartedMicros
}
