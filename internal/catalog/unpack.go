package catalog

import (
	"archive/tar"
	"archive/zip"
	"compress/bzip2"
	"compress/gzip"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

func archivePath(root, name string) (string, error) {
	name = path.Clean(name)
	if name == ".." || strings.HasPrefix(name, "../") || path.IsAbs(name) || strings.ContainsAny(name, "\\:\x00") {
		return "", errors.New("adapter archive contains an unsafe path")
	}
	return filepath.Join(root, filepath.FromSlash(name)), nil
}

func unpackBinary(archive, root string, binary Binary) (string, error) {
	return unpackArchive(archive, root, binary, true)
}

func unpackArchive(archive, root string, binary Binary, executable bool) (string, error) {
	command, err := archivePath(root, binary.Command)
	if err != nil || command == root {
		return "", errors.New("invalid adapter executable path")
	}
	address, err := readURL(binary.Archive)
	if err != nil {
		return "", err
	}
	var remaining int64 = maxBinaryBytes
	write := func(name string, mode os.FileMode, size int64, content io.Reader) error {
		target, err := archivePath(root, name)
		if err != nil {
			return err
		}
		if mode.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		if !mode.IsRegular() || size < 0 || size > remaining {
			return errors.New("adapter archive contains a special file or exceeds its unpacked size limit")
		}
		remaining -= size
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		mode = 0400 | mode.Perm()&0100
		if executable && target == command {
			mode = 0500
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			return err
		}
		_, err = io.CopyN(out, content, size)
		return errors.Join(err, out.Close())
	}
	name := strings.ToLower(address.Path)
	switch {
	case strings.HasSuffix(name, ".zip"):
		z, err := zip.OpenReader(archive)
		if err != nil {
			return "", err
		}
		defer z.Close()
		if len(z.File) > 8192 {
			return "", errors.New("too many entries in adapter archive")
		}
		for _, entry := range z.File {
			content, err := entry.Open()
			if err != nil {
				return "", err
			}
			err = write(entry.Name, entry.Mode(), int64(entry.UncompressedSize64), content)
			content.Close()
			if err != nil {
				return "", err
			}
		}
	case strings.HasSuffix(name, ".tar.gz"), strings.HasSuffix(name, ".tgz"),
		strings.HasSuffix(name, ".tar.bz2"), strings.HasSuffix(name, ".tbz2"):
		file, err := os.Open(archive)
		if err != nil {
			return "", err
		}
		defer file.Close()
		var content io.Reader = bzip2.NewReader(file)
		if strings.HasSuffix(name, ".gz") || strings.HasSuffix(name, ".tgz") {
			gz, err := gzip.NewReader(file)
			if err != nil {
				return "", err
			}
			defer gz.Close()
			content = gz
		}
		reader := tar.NewReader(content)
		for count := 0; ; count++ {
			header, err := reader.Next()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return "", err
			}
			if count >= 8192 {
				return "", errors.New("too many entries in adapter archive")
			}
			if err := write(header.Name, header.FileInfo().Mode(), header.Size, reader); err != nil {
				return "", err
			}
		}
	default:
		if !executable {
			return "", errors.New("offline package bundles must be zip or supported tar archives")
		}
		for _, suffix := range []string{".dmg", ".pkg", ".deb", ".rpm", ".msi", ".appimage"} {
			if strings.HasSuffix(name, suffix) {
				return "", errors.New("installer packages are outside the ACP binary archive format")
			}
		}
		file, err := os.Open(archive)
		if err != nil {
			return "", err
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil {
			return "", err
		}
		if err := write(binary.Command, 0500, info.Size(), file); err != nil {
			return "", err
		}
	}
	if !executable {
		return command, nil
	}
	info, err := os.Stat(command)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0100 == 0 {
		return "", errors.New("adapter executable is missing from the archive")
	}
	return command, nil
}
