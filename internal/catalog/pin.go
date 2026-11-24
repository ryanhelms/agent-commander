package catalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

type InstalledBinary struct {
	StagedBinary
	Command string            `json:"command"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

type pin struct {
	Current      InstalledBinary   `json:"current"`
	Previous     *InstalledBinary  `json:"previous,omitempty"`
	Releases     map[string]string `json:"releases"`
	UpdateSource *updateSource     `json:"update_source,omitempty"`
	Notice       *Notice           `json:"verified_update_notice,omitempty"`
}

var profileID = regexp.MustCompile(`^[a-z0-9_-]{1,100}$`)
var stageID = regexp.MustCompile(`^stage-[0-9]+$`)

func LoadPin(state, id string) (*InstalledBinary, error) {
	value, err := readPin(state, id)
	if err != nil || value == nil {
		return nil, err
	}
	return &value.Current, nil
}

func readPin(state, id string) (*pin, error) {
	if !profileID.MatchString(id) || id == "claude" || id == "codex" {
		return nil, nil
	}
	raw, err := os.ReadFile(filepath.Join(state, "catalog", "pins", id+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var p pin
	if err := json.Unmarshal(raw, &p); err != nil || p.Current.ID != id || !filepath.IsAbs(p.Current.Command) {
		return nil, errors.New("invalid adapter pin")
	}
	return &p, nil
}

func Activate(ctx context.Context, state, stage, fingerprint string) (InstalledBinary, error) {
	return activate(ctx, state, stage, fingerprint, probeACP)
}

func readStagedBinary(state, stage string) (Binary, StagedBinary, error) {
	if !stageID.MatchString(stage) {
		return Binary{}, StagedBinary{}, errors.New("expected a staged binary ID")
	}
	root := filepath.Join(state, "catalog")
	dir := filepath.Join(root, "staged", stage)
	raw, err := os.ReadFile(filepath.Join(dir, "receipt.json"))
	if err != nil {
		return Binary{}, StagedBinary{}, err
	}
	var receipt StagedBinary
	if err := json.Unmarshal(raw, &receipt); err != nil || !profileID.MatchString(receipt.ID) || receipt.ID == "claude" || receipt.ID == "codex" {
		return Binary{}, StagedBinary{}, errors.New("invalid staged receipt or reserved profile ID")
	}
	var proof BinaryProof
	for name, dest := range map[string]*[]byte{"publisher-entry.json": &proof.Manifest, "publisher-entry.sig": &proof.Signature, "publisher.pem": &proof.PublicKey} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return Binary{}, StagedBinary{}, err
		}
		*dest = data
	}
	var entry Agent
	if err := json.Unmarshal(proof.Manifest, &entry); err != nil {
		return Binary{}, StagedBinary{}, err
	}
	binary, verified, err := verifyRelease(Snapshot{Source: receipt.Catalog, SHA256: receipt.CatalogSHA256, HostPlatform: hostPlatform(), Agents: []Agent{entry}}, receipt.ID, receipt.Version, receipt.PackageManager, proof)
	if err != nil {
		return Binary{}, StagedBinary{}, err
	}
	if verified.PublisherKeySHA256 != receipt.PublisherKeySHA256 || verified.ManifestSHA256 != receipt.ManifestSHA256 ||
		verified.ArtifactSHA256 != receipt.ArtifactSHA256 || verified.Platform != receipt.Platform || verified.PackageSpec != receipt.PackageSpec {
		return Binary{}, StagedBinary{}, errors.New("staged binary does not match its verification receipt")
	}
	verified.Directory = dir
	return binary, verified, nil
}

func activate(ctx context.Context, state, stage, fingerprint string, probe func(context.Context, InstalledBinary) error) (InstalledBinary, error) {
	binary, verified, err := readStagedBinary(state, stage)
	if err != nil {
		return InstalledBinary{}, err
	}
	if !strings.EqualFold(fingerprint, verified.PublisherKeySHA256) {
		return InstalledBinary{}, errors.New("staged binary does not match the trusted publisher")
	}
	root := filepath.Join(state, "catalog")
	if err := os.MkdirAll(filepath.Join(root, "installed"), 0700); err != nil {
		return InstalledBinary{}, err
	}
	unlock, err := lockPins(ctx, root)
	if err != nil {
		return InstalledBinary{}, err
	}
	defer unlock()
	current, err := readPin(state, verified.ID)
	if err != nil {
		return InstalledBinary{}, err
	}
	var previous *InstalledBinary
	releases := make(map[string]string)
	if current != nil {
		pinned := current.Current
		if pinned.PublisherKeySHA256 != verified.PublisherKeySHA256 || pinned.Catalog != verified.Catalog {
			return InstalledBinary{}, errors.New("active profile belongs to a different publisher or catalog")
		}
		for version, digest := range current.Releases {
			releases[version] = digest
		}
		if digest, ok := releases[verified.Version]; ok && digest != verified.ManifestSHA256 {
			return InstalledBinary{}, errors.New("publisher reused a version for a different release")
		}
		if pinned.Version == verified.Version {
			if pinned.ManifestSHA256 != verified.ManifestSHA256 {
				return InstalledBinary{}, errors.New("publisher reused a version for a different release")
			}
			if err := verifyStagedArchive(ctx, verified); err != nil {
				return InstalledBinary{}, err
			}
			return pinned, nil
		}
		previous = &pinned
	}
	install, err := os.MkdirTemp(filepath.Join(root, "installed"), "binary-")
	if err != nil {
		return InstalledBinary{}, err
	}
	keep := false
	defer func() {
		if !keep {
			_ = os.RemoveAll(install)
		}
	}()
	// Copy and verify the archive before unpacking to avoid a check/use gap.
	archive, err := os.Open(filepath.Join(verified.Directory, "archive"))
	if err != nil {
		return InstalledBinary{}, err
	}
	copyPath := filepath.Join(install, "archive")
	err = stageArchive(ctx, copyPath, archive, verified.ArtifactSHA256)
	archive.Close()
	if err != nil {
		return InstalledBinary{}, err
	}
	files := filepath.Join(install, "files")
	var command string
	if verified.PackageManager == "" {
		command, err = unpackBinary(copyPath, files, binary)
	} else {
		command, err = unpackArchive(copyPath, files, binary, false)
		if err == nil {
			err = installPackage(ctx, files, command, verified.PackageManager, verified.PackageSpec)
		}
	}
	if err != nil {
		return InstalledBinary{}, err
	}
	if err := os.Remove(copyPath); err != nil {
		return InstalledBinary{}, err
	}
	installed := InstalledBinary{StagedBinary: verified, Command: command, Args: binary.Args, Env: binary.Env}
	installed.Directory = install
	if err := probe(ctx, installed); err != nil {
		return InstalledBinary{}, fmt.Errorf("ACP compatibility check: %w", err)
	}
	releases[installed.Version] = installed.ManifestSHA256
	next := pin{Current: installed, Previous: previous, Releases: releases}
	if current != nil {
		next.UpdateSource = current.UpdateSource
		next.Notice = current.noticeFor(installed.Version)
	}
	if err := writePin(ctx, root, verified.ID, next); err != nil {
		return InstalledBinary{}, err
	}
	keep = true
	return installed, nil
}

func Rollback(ctx context.Context, state, id string) (InstalledBinary, error) {
	root := filepath.Join(state, "catalog")
	unlock, err := lockPins(ctx, root)
	if err != nil {
		return InstalledBinary{}, err
	}
	defer unlock()
	current, err := readPin(state, id)
	if err != nil {
		return InstalledBinary{}, err
	}
	if current == nil || current.Previous == nil {
		return InstalledBinary{}, errors.New("adapter has no previous verified installation")
	}
	next := pin{Current: *current.Previous, Previous: &current.Current, Releases: current.Releases, UpdateSource: current.UpdateSource}
	next.Notice = current.noticeFor(next.Current.Version)
	if _, err := exec.LookPath(next.Current.Command); err != nil {
		return InstalledBinary{}, err
	}
	return next.Current, writePin(ctx, root, id, next)
}

func lockPins(ctx context.Context, root string) (func(), error) {
	if err := os.MkdirAll(filepath.Join(root, "pins"), 0700); err != nil {
		return nil, err
	}
	return lockCatalogFile(ctx, filepath.Join(root, "pins.lock"))
}

func lockCatalogFile(ctx context.Context, path string) (func(), error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	retry := time.NewTicker(25 * time.Millisecond)
	defer retry.Stop()
	for ctx.Err() == nil {
		switch err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err {
		case nil:
			if ctx.Err() == nil {
				return func() { _ = file.Close() }, nil
			}
		case syscall.EINTR:
			continue
		case syscall.EWOULDBLOCK:
			select {
			case <-ctx.Done():
			case <-retry.C:
			}
		default:
			_ = file.Close()
			return nil, err
		}
	}
	_ = file.Close()
	return nil, ctx.Err()
}

func writePin(ctx context.Context, root, id string, value pin) error {
	dir := filepath.Join(root, "pins")
	file, err := os.CreateTemp(dir, ".pin-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(value)
	if err = errors.Join(err, file.Close()); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return os.Rename(file.Name(), filepath.Join(dir, id+".json"))
}

func probeACP(ctx context.Context, installed InstalledBinary) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, installed.Command, installed.Args...)
	cmd.Dir = filepath.Dir(installed.Command)
	cmd.Env = os.Environ()
	for key, value := range installed.Env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	cmd.WaitDelay = time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	defer stdin.Close()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	stop := context.AfterFunc(ctx, func() { _ = stdout.Close() })
	defer stop()
	if _, err := io.WriteString(stdin, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"Agent Commander","version":"1"}}}`+"\n"); err != nil {
		return err
	}
	decoder := json.NewDecoder(io.LimitReader(stdout, 1<<20))
	for {
		var message struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Result  struct {
				ProtocolVersion int `json:"protocolVersion"`
			} `json:"result"`
		}
		if err := decoder.Decode(&message); err != nil {
			return errors.Join(errors.New("adapter did not complete ACP initialization"), ctx.Err())
		}
		if string(message.ID) != "1" {
			continue
		}
		if message.JSONRPC != "2.0" || message.Result.ProtocolVersion != 1 {
			return errors.New("adapter did not negotiate ACP v1")
		}
		return nil
	}
}
