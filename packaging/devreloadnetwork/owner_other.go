//go:build !darwin || !cgo

package main

import (
	"context"
	"errors"
)

var errPlatform = errors.New("socket owner verification requires macOS with cgo")

func listeningProcesses(context.Context, string) ([]int, error) { return nil, errPlatform }
func inspectProcess(int) (*process, error)                      { return nil, errPlatform }

func ownsServeArguments(int) (bool, error) { return false, errPlatform }
