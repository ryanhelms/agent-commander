// Command headless packages the headless Commander release assets from
// already built Linux agentctl binaries:
//
//	go run ./packaging/headless --version v0.2.0-pilot.4 --output release-assets \
//	  --binary amd64=dist/agentctl-linux-amd64 --binary arm64=dist/agentctl-linux-arm64
//
// It checks that each binary is a static Linux executable for its
// architecture and, for a release tag, that it was stamped with that tag. It
// writes agent-commander-headless-linux-ARCH.tar.gz and copies install.sh.
// The archives are reproducible: fixed times, owners and modes.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"debug/buildinfo"
	"debug/elf"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	top        = "agent-commander-headless"
	versionVar = "agentcommander/internal/buildinfo.Version="
)

var machines = map[string]elf.Machine{"amd64": elf.EM_X86_64, "arm64": elf.EM_AARCH64}

var tagPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)

const readme = `# Agent Commander headless service

Install or upgrade it on this server:

    ./agentctl host install

Check what the server still needs:

    ./agentctl host doctor

Deploy from a Mac instead with ` + "`agentctl host deploy DESTINATION`" + `.
`

type binaries map[string]string

func (b binaries) String() string { return fmt.Sprint(map[string]string(b)) }

func (b binaries) Set(value string) error {
	arch, path, ok := strings.Cut(value, "=")
	if _, known := machines[arch]; !ok || !known || path == "" {
		return fmt.Errorf("--binary takes amd64=PATH or arm64=PATH, not %q", value)
	}
	b[arch] = path
	return nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "headless:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("headless", flag.ContinueOnError)
	version := fs.String("version", "", "release tag stamped into the binaries")
	output := fs.String("output", "", "directory for the assets")
	install := fs.String("install-script", "deploy/headless/install.sh", "install.sh to publish")
	bins := binaries{}
	fs.Var(bins, "binary", "ARCH=PATH for a Linux agentctl; repeat for each architecture")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !tagPattern.MatchString(*version) || *output == "" || len(bins) != len(machines) {
		return errors.New("usage: headless --version TAG --output DIR --binary amd64=PATH --binary arm64=PATH")
	}
	if err := os.MkdirAll(*output, 0755); err != nil {
		return err
	}
	arches := make([]string, 0, len(bins))
	for arch := range bins {
		arches = append(arches, arch)
	}
	sort.Strings(arches)
	for _, arch := range arches {
		data, err := checkBinary(bins[arch], arch, *version)
		if err != nil {
			return err
		}
		archive, err := pack(data, *version)
		if err != nil {
			return err
		}
		name := filepath.Join(*output, "agent-commander-headless-linux-"+arch+".tar.gz")
		if err := os.WriteFile(name, archive, 0644); err != nil {
			return err
		}
		fmt.Println(name)
	}
	script, err := os.ReadFile(*install)
	if err != nil {
		return err
	}
	if !bytes.HasPrefix(script, []byte("#!/bin/sh\n")) {
		return errors.New("install.sh must start with #!/bin/sh")
	}
	name := filepath.Join(*output, "install.sh")
	if err := os.WriteFile(name, script, 0755); err != nil {
		return err
	}
	fmt.Println(name)
	return nil
}

// checkBinary reads one agentctl and checks its format and version stamp.
func checkBinary(path, arch, version string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	f, err := elf.NewFile(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%s is not a Linux executable: %w", path, err)
	}
	defer f.Close()
	if f.Machine != machines[arch] || f.Type != elf.ET_EXEC {
		return nil, fmt.Errorf("%s is %v %v, not a %s executable", path, f.Machine, f.Type, arch)
	}
	for _, p := range f.Progs {
		if p.Type == elf.PT_INTERP {
			return nil, fmt.Errorf("%s is dynamically linked; build it with CGO_ENABLED=0", path)
		}
	}
	info, err := buildinfo.Read(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%s has no Go build information: %w", path, err)
	}
	if info.Path != "agentcommander/cmd/agentctl" {
		return nil, fmt.Errorf("%s is %s, not agentctl", path, info.Path)
	}
	if strings.HasPrefix(version, "v") {
		stamped, err := stampedVersion(f)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if stamped != version {
			return nil, fmt.Errorf("%s is stamped %q, not %s; build it with -ldflags \"-X %s%s\"", path, stamped, version, versionVar, version)
		}
	}
	return data, nil
}

// stampedVersion reads the string variable buildinfo.Version from the
// symbol table. Go records -ldflags in the build information only without
// -trimpath, so the value itself is the reliable check.
func stampedVersion(f *elf.File) (string, error) {
	symbols, err := f.Symbols()
	if err != nil {
		return "", fmt.Errorf("read symbols: %w", err)
	}
	name := strings.TrimSuffix(versionVar, "=")
	for _, sym := range symbols {
		if sym.Name != name {
			continue
		}
		header, err := readAt(f, sym.Value, 16)
		if err != nil {
			return "", err
		}
		ptr, size := f.ByteOrder.Uint64(header[:8]), f.ByteOrder.Uint64(header[8:])
		if size == 0 {
			return "", nil
		}
		if size > 64 {
			return "", errors.New("the version string is too long")
		}
		value, err := readAt(f, ptr, size)
		return string(value), err
	}
	return "", errors.New("no buildinfo.Version symbol; do not strip the binary")
}

func readAt(f *elf.File, addr, size uint64) ([]byte, error) {
	for _, sec := range f.Sections {
		if sec.Type != elf.SHT_NOBITS && addr >= sec.Addr && addr+size <= sec.Addr+sec.Size {
			out := make([]byte, size)
			_, err := sec.ReadAt(out, int64(addr-sec.Addr))
			return out, err
		}
	}
	return nil, fmt.Errorf("address %#x is outside the binary's sections", addr)
}

// pack writes the archive: one directory with agentctl, VERSION and README.
func pack(binary []byte, version string) ([]byte, error) {
	var out bytes.Buffer
	gz, err := gzip.NewWriterLevel(&out, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	gz.ModTime = time.Unix(0, 0)
	tw := tar.NewWriter(gz)
	stamp := time.Unix(0, 0).UTC()
	entries := []struct {
		name string
		mode int64
		data []byte
	}{
		{top + "/agentctl", 0755, binary},
		{top + "/VERSION", 0644, []byte(version + "\n")},
		{top + "/README.md", 0644, []byte(readme)},
	}
	if err := tw.WriteHeader(&tar.Header{Name: top + "/", Typeflag: tar.TypeDir, Mode: 0755, ModTime: stamp, Format: tar.FormatPAX}); err != nil {
		return nil, err
	}
	for _, e := range entries {
		if err := tw.WriteHeader(&tar.Header{Name: e.name, Mode: e.mode, Size: int64(len(e.data)), ModTime: stamp, Typeflag: tar.TypeReg, Format: tar.FormatPAX}); err != nil {
			return nil, err
		}
		if _, err := tw.Write(e.data); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
