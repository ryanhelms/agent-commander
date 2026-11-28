package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// The kernel socket path is a whole NUL-delimited name field from lsof. A
// process can have multiple FDs for the same socket and is counted only once.
func socketPIDs(output []byte, socket, canonical string) ([]int, error) {
	owners := make(map[int]bool)
	pid := 0
	for _, field := range strings.Split(string(output), "\x00") {
		field = strings.TrimPrefix(field, "\n")
		if field == "" {
			continue
		}
		switch field[0] {
		case 'p':
			var err error
			pid, err = strconv.Atoi(field[1:])
			if err != nil || pid <= 0 {
				return nil, fmt.Errorf("invalid PID in Unix socket listing")
			}
		case 'n':
			if field[1:] != socket && field[1:] != canonical {
				continue
			}
			if pid <= 0 {
				return nil, fmt.Errorf("no PID for %s in Unix socket listing", socket)
			}
			owners[pid] = true
		}
	}
	pids := make([]int, 0, len(owners))
	for pid := range owners {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	return pids, nil
}
