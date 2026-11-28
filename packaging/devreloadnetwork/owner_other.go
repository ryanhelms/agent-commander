//go:build !darwin || !cgo

package main

import (
	"context"
	"errors"
)

var errPlatform = errors.New("dev network reload requires macOS with cgo")

func listeningProcesses(context.Context, string) ([]int, error) { return nil, errPlatform }
func inspectProcess(int) (*process, error)                      { return nil, errPlatform }
