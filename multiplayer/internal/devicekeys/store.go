package devicekeys

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type Store interface {
	Load() ([]byte, error)
	Save([]byte) error
	Delete() error
}

// Directory is an explicit disposable alternative for automated/headless tests.
func Directory(path string) (Store, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("device test store needs an absolute directory")
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return nil, err
	}
	f, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !f.IsDir() || f.Mode().Perm()&0077 != 0 {
		return nil, errors.New("device test store must be a private directory (0700)")
	}
	return dirStore(filepath.Join(path, "device.json")), nil
}

type dirStore string

const maxRecord = 1 << 20

func (s dirStore) Load() ([]byte, error) {
	st, err := os.Lstat(string(s))
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() > maxRecord {
		return nil, errors.New("invalid device store file")
	}
	f, err := os.Open(string(s))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxRecord+1))
	if len(b) > maxRecord {
		return nil, errors.New("oversized credential record")
	}
	return b, err
}
func (s dirStore) Save(data []byte) error {
	if len(data) == 0 || len(data) > maxRecord {
		return fmt.Errorf("invalid credential record size")
	}
	f, err := os.CreateTemp(filepath.Dir(string(s)), ".device-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), string(s)); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(string(s)))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
func (s dirStore) Delete() error {
	err := os.Remove(string(s))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
