package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Image struct {
	ID           string
	Name         string
	Box          string
	Version      string
	Architecture string
	Provisioner  string
}

type VMConfig struct {
	Name            string
	Memory          int
	MaxMemory       int
	CPUs            int
	IP              string
	Gateway         string
	Switch          string
	Box             string
	BoxVersion      string
	BoxArchitecture string
	Provisioner     string
	IPTimeout       int
}

var (
	supportedImages = []Image{
		{ID: "ubuntu22", Name: "Ubuntu 22", Box: "generic/ubuntu2204", Version: "4.3.12", Architecture: "amd64", Provisioner: "ubuntu"},
		{ID: "debian9", Name: "Debian 9", Box: "generic/debian9", Version: "4.3.12", Architecture: "amd64", Provisioner: "debian"},
	}
	validName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

func (app *App) imagesDir() string  { return filepath.Join(app.home, "images") }
func (app *App) configsDir() string { return filepath.Join(app.home, "configs") }
func (app *App) vmsDir() string     { return filepath.Join(app.home, "vms") }
func (app *App) configPath(name string) string {
	return filepath.Join(app.configsDir(), name+".env")
}
func (app *App) vmDir(name string) string { return filepath.Join(app.vmsDir(), name) }

func (app *App) ensureLayout() error {
	for _, directory := range []string{app.home, app.imagesDir(), app.configsDir(), app.vmsDir()} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return fmt.Errorf("creazione directory %s: %w", directory, err)
		}
	}
	for _, image := range supportedImages {
		path := filepath.Join(app.imagesDir(), image.ID+".env")
		content := fmt.Sprintf("IMAGE_NAME=%s\nVM_BOX=%s\nVM_BOX_VERSION=%s\nVM_BOX_ARCHITECTURE=%s\nVM_PROVISIONER=%s\n", image.Name, image.Box, image.Version, image.Architecture, image.Provisioner)
		if err := writeIfMissing(path, []byte(content)); err != nil {
			return err
		}
	}
	return nil
}

func writeIfMissing(path string, content []byte) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		return fmt.Errorf("scrittura %s: %w", path, err)
	}
	return nil
}

func validateConfig(config VMConfig) error {
	if !validName.MatchString(config.Name) {
		return errors.New("nome VM non valido")
	}
	if config.Memory < 128 || config.MaxMemory < config.Memory || config.CPUs < 1 || config.IPTimeout < 1 {
		return errors.New("valori numerici della configurazione non validi")
	}
	if net.ParseIP(config.IP) == nil || net.ParseIP(config.Gateway) == nil {
		return errors.New("IP o gateway non valido")
	}
	for _, value := range []string{config.Switch, config.Box, config.BoxVersion, config.BoxArchitecture, config.Provisioner} {
		if value == "" || strings.ContainsAny(value, "\r\n=") {
			return errors.New("configurazione incompleta o contenente caratteri non validi")
		}
	}
	for _, image := range supportedImages {
		if config.Box == image.Box && config.Provisioner == image.Provisioner {
			return nil
		}
	}
	return errors.New("sono supportate solo le immagini Ubuntu 22 e Debian 9")
}

func (app *App) saveConfig(config VMConfig) error {
	content := fmt.Sprintf("VM_NAME=%s\nVM_MEMORY=%d\nVM_MAX_MEMORY=%d\nVM_CPUS=%d\nVM_IP=%s\nVM_GATEWAY=%s\nVM_SWITCH=%s\nVM_BOX=%s\nVM_BOX_VERSION=%s\nVM_BOX_ARCHITECTURE=%s\nVM_PROVISIONER=%s\nVM_IP_TIMEOUT=%d\n", config.Name, config.Memory, config.MaxMemory, config.CPUs, config.IP, config.Gateway, config.Switch, config.Box, config.BoxVersion, config.BoxArchitecture, config.Provisioner, config.IPTimeout)
	temporary := app.configPath(config.Name) + ".tmp"
	if err := os.WriteFile(temporary, []byte(content), 0o600); err != nil {
		return fmt.Errorf("scrittura configurazione: %w", err)
	}
	if err := os.Rename(temporary, app.configPath(config.Name)); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("salvataggio configurazione: %w", err)
	}
	return nil
}

func (app *App) loadAllConfigs() ([]VMConfig, error) {
	entries, err := os.ReadDir(app.configsDir())
	if err != nil {
		return nil, err
	}
	configs := make([]VMConfig, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".env") {
			continue
		}
		config, err := loadConfig(filepath.Join(app.configsDir(), entry.Name()))
		if err != nil {
			return nil, fmt.Errorf("lettura %s: %w", entry.Name(), err)
		}
		configs = append(configs, config)
	}
	sort.Slice(configs, func(left, right int) bool { return configs[left].Name < configs[right].Name })
	return configs, nil
}

func loadConfig(path string) (VMConfig, error) {
	file, err := os.Open(path)
	if err != nil {
		return VMConfig{}, err
	}
	defer file.Close()
	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			return VMConfig{}, fmt.Errorf("riga non valida: %q", line)
		}
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	if err := scanner.Err(); err != nil {
		return VMConfig{}, err
	}
	integer := func(key string) (int, error) {
		value, err := strconv.Atoi(values[key])
		if err != nil {
			return 0, fmt.Errorf("%s non valido", key)
		}
		return value, nil
	}
	config := VMConfig{Name: values["VM_NAME"], IP: values["VM_IP"], Gateway: values["VM_GATEWAY"], Switch: values["VM_SWITCH"], Box: values["VM_BOX"], BoxVersion: values["VM_BOX_VERSION"], BoxArchitecture: values["VM_BOX_ARCHITECTURE"], Provisioner: values["VM_PROVISIONER"]}
	if config.Memory, err = integer("VM_MEMORY"); err != nil {
		return VMConfig{}, err
	}
	if config.MaxMemory, err = integer("VM_MAX_MEMORY"); err != nil {
		return VMConfig{}, err
	}
	if config.CPUs, err = integer("VM_CPUS"); err != nil {
		return VMConfig{}, err
	}
	if config.IPTimeout, err = integer("VM_IP_TIMEOUT"); err != nil {
		return VMConfig{}, err
	}
	return config, validateConfig(config)
}
