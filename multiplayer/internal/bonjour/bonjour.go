// Package bonjour advertises and browses Commander relays over DNS-SD
// (Bonjour). It drives the system responder through its command-line tools,
// dns-sd on macOS and avahi-publish-service on Linux, so it never competes
// with mDNSResponder or Avahi for the multicast port.
// See design/COMMANDER-NETWORK-DISCOVERY.md.
package bonjour

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// ServiceType is the DNS-SD service type of a Commander relay.
const ServiceType = "_agentcommander._tcp"

const (
	domain          = "local."
	resolveTimeout  = 3 * time.Second
	registerTimeout = 5 * time.Second
	maxInstances    = 64
	maxTXTValue     = 200
)

// ErrUnavailable reports that this system has no usable Bonjour tool.
var ErrUnavailable = errors.New("no Bonjour responder tool on this system")

// Service is a relay to advertise.
type Service struct {
	Name string
	Port int
	TXT  map[string]string
}

// Instance is one resolved relay advertisement.
type Instance struct {
	Name string            `json:"name"`
	Host string            `json:"host"`
	Port int               `json:"port"`
	TXT  map[string]string `json:"txt"`
}

// Tools locates the responder tools. Empty paths use the system defaults.
type Tools struct {
	DNSSD string // dns-sd (macOS)
	Avahi string // avahi-publish-service (Linux)
}

func (t Tools) dnssd() (string, error) {
	if t.DNSSD != "" {
		return executable(t.DNSSD)
	}
	if p, err := executable("/usr/bin/dns-sd"); err == nil {
		return p, nil
	}
	if p, err := exec.LookPath("dns-sd"); err == nil {
		return p, nil
	}
	return "", ErrUnavailable
}

func (t Tools) avahi() (string, error) {
	if t.Avahi != "" {
		return executable(t.Avahi)
	}
	if p, err := exec.LookPath("avahi-publish-service"); err == nil {
		return p, nil
	}
	return "", ErrUnavailable
}

func executable(p string) (string, error) {
	st, err := os.Stat(p)
	if err != nil || st.IsDir() || st.Mode()&0111 == 0 {
		return "", ErrUnavailable
	}
	return p, nil
}

var txtKey = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// CleanName makes a valid DNS-SD instance name: printable, at most 63 bytes.
func CleanName(name string) string {
	name = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	for len(name) > 63 {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	return strings.TrimSpace(name)
}

func (s Service) validate() error {
	if CleanName(s.Name) == "" {
		return errors.New("bonjour: service name required")
	}
	if s.Port <= 0 || s.Port > 65535 {
		return errors.New("bonjour: invalid port")
	}
	for k, v := range s.TXT {
		if !txtKey.MatchString(k) || len(v) > maxTXTValue || strings.ContainsAny(v, "\r\n\x00") {
			return fmt.Errorf("bonjour: invalid TXT entry %q", k)
		}
	}
	return nil
}

func (s Service) txtArgs() []string {
	keys := make([]string, 0, len(s.TXT))
	for k := range s.TXT {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+s.TXT[k])
	}
	return out
}

// Advertise registers s with the system responder until stop is called or
// ctx ends. It returns once the responder confirms the registration.
func (t Tools) Advertise(ctx context.Context, s Service) (stop func(), err error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	name, port := CleanName(s.Name), strconv.Itoa(s.Port)
	var cmd *exec.Cmd
	ctx, cancel := context.WithCancel(ctx)
	if p, err := t.dnssd(); err == nil {
		cmd = exec.CommandContext(ctx, p, append([]string{"-R", name, ServiceType, domain, port}, s.txtArgs()...)...)
	} else if p, err := t.avahi(); err == nil {
		cmd = exec.CommandContext(ctx, p, append([]string{name, ServiceType, port}, s.txtArgs()...)...)
	} else {
		cancel()
		return nil, ErrUnavailable
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	cmd.Stderr = cmd.Stdout // avahi reports success on stderr
	if err = cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("bonjour: start responder tool: %w", err)
	}
	registered := make(chan struct{})
	var once sync.Once
	exited := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			line := sc.Text()
			if strings.Contains(line, "registered and active") || strings.Contains(line, "Established under name") {
				once.Do(func() { close(registered) })
			}
		}
		_ = cmd.Wait()
		close(exited)
	}()
	stopped := func() {
		cancel()
		<-exited
	}
	timer := time.NewTimer(registerTimeout)
	defer timer.Stop()
	select {
	case <-registered:
		return sync.OnceFunc(stopped), nil
	case <-exited:
		cancel()
		return nil, errors.New("bonjour: the responder tool exited before registering")
	case <-timer.C:
		stopped()
		return nil, errors.New("bonjour: the responder did not confirm the registration")
	case <-ctx.Done():
		stopped()
		return nil, ctx.Err()
	}
}

// Browse lists relays advertised during window, resolved to host, port and TXT.
func (t Tools) Browse(ctx context.Context, window time.Duration) ([]Instance, error) {
	p, err := t.dnssd()
	if err != nil {
		return nil, err
	}
	bctx, cancel := context.WithTimeout(ctx, window)
	defer cancel()
	cmd := exec.CommandContext(bctx, p, "-B", ServiceType, domain)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		return nil, fmt.Errorf("bonjour: start dns-sd: %w", err)
	}
	names := parseBrowse(out)
	_ = cmd.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	found := make([]Instance, len(names))
	ok := make([]bool, len(names))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, n := range names {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if in, err := t.resolve(ctx, p, n); err == nil {
				found[i], ok[i] = in, true
			}
		}()
	}
	wg.Wait()
	list := []Instance{}
	for i := range found {
		if ok[i] {
			list = append(list, found[i])
		}
	}
	return list, nil
}

var browseLine = regexp.MustCompile(`^\s*\S+\s+(Add|Rmv)\s+\d+\s+\d+\s+\S+\s+\S+\s+(.+)$`)

// parseBrowse reads `dns-sd -B` output until it ends and returns the instance
// names still present. One service shows up once per interface.
func parseBrowse(r io.Reader) []string {
	count := map[string]int{}
	order := []string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		m := browseLine.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		name := strings.TrimSpace(m[2])
		if _, seen := count[name]; !seen {
			if len(order) >= maxInstances {
				continue
			}
			order = append(order, name)
		}
		if m[1] == "Add" {
			count[name]++
		} else if count[name] > 0 {
			count[name]--
		}
	}
	out := []string{}
	for _, n := range order {
		if count[n] > 0 {
			out = append(out, n)
		}
	}
	return out
}

func (t Tools) resolve(ctx context.Context, dnssd, name string) (Instance, error) {
	ctx, cancel := context.WithTimeout(ctx, resolveTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, dnssd, "-L", name, ServiceType, domain)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return Instance{}, err
	}
	if err = cmd.Start(); err != nil {
		return Instance{}, err
	}
	defer func() {
		cancel()
		_ = cmd.Wait()
	}()
	in, err := parseLookup(out)
	if err != nil {
		return Instance{}, err
	}
	in.Name = name
	return in, nil
}

var reachLine = regexp.MustCompile(`can be reached at (\S+):(\d+) \(interface \d+\)`)

// parseLookup reads `dns-sd -L` output up to the first answer and its TXT line.
func parseLookup(r io.Reader) (Instance, error) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		m := reachLine.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		port, err := strconv.Atoi(m[2])
		if err != nil || port <= 0 || port > 65535 {
			return Instance{}, errors.New("bonjour: invalid port in lookup")
		}
		in := Instance{Host: strings.TrimSuffix(m[1], "."), Port: port, TXT: map[string]string{}}
		if sc.Scan() && strings.HasPrefix(sc.Text(), " ") {
			in.TXT = parseTXT(sc.Text())
		}
		return in, nil
	}
	return Instance{}, errors.New("bonjour: no answer to lookup")
}

// parseTXT splits a dns-sd TXT line. dns-sd escapes spaces and backslashes
// with a backslash and other bytes as \DDD.
func parseTXT(line string) map[string]string {
	out := map[string]string{}
	var tokens []string
	var cur []byte
	inToken := false
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case c == '\\' && i+3 < len(line) && isDigits(line[i+1:i+4]):
			n, _ := strconv.Atoi(line[i+1 : i+4])
			cur, inToken = append(cur, byte(n)), true
			i += 3
		case c == '\\' && i+1 < len(line):
			cur, inToken = append(cur, line[i+1]), true
			i++
		case c == ' ':
			if inToken {
				tokens = append(tokens, string(cur))
				cur, inToken = nil, false
			}
		default:
			cur, inToken = append(cur, c), true
		}
	}
	if inToken {
		tokens = append(tokens, string(cur))
	}
	for _, tok := range tokens {
		k, v, _ := strings.Cut(tok, "=")
		k = strings.ToLower(k)
		if txtKey.MatchString(k) && len(v) <= maxTXTValue {
			out[k] = v
		}
	}
	return out
}

func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
