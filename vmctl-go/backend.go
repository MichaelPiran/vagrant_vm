package main

import (
	"encoding/csv"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func (app *App) writeVMAssets(config VMConfig) error {
	directory := app.vmDir(config.Name)
	if err := os.MkdirAll(filepath.Join(directory, "provisioners"), 0o755); err != nil {
		return err
	}
	assets := map[string]string{
		filepath.Join(directory, "Vagrantfile"):               vagrantfileTemplate,
		filepath.Join(directory, "provisioners", "ubuntu.sh"): ubuntuProvisioner,
		filepath.Join(directory, "provisioners", "debian.sh"): debianProvisioner,
		filepath.Join(directory, "provisioners", "arch.sh"):   archProvisioner,
		filepath.Join(directory, "provisioners", "alpine.sh"): alpineProvisioner,
		filepath.Join(directory, "info.txt"):                  fmt.Sprintf("Nome VM: %s\nImmagine: %s\nIP statico: %s\nRAM: %d MB\nvCPU: %d\nCreata il: %s\n", config.Name, config.Box, config.IP, config.Memory, config.CPUs, time.Now().Format("02/01/2006 15:04:05")),
	}
	for path, content := range assets {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return fmt.Errorf("scrittura %s: %w", path, err)
		}
	}
	return nil
}

func (app *App) printVMs() error {
	configs, err := app.loadAllConfigs()
	if err != nil {
		return err
	}
	if len(configs) == 0 {
		fmt.Fprintln(app.out, "Nessuna VM creata.")
		return nil
	}
	states := app.vmStates(configs)
	fmt.Fprintf(app.out, "%-24s %-12s %-16s %s\n", "NOME", "STATO", "IP", "IMMAGINE")
	for _, config := range configs {
		fmt.Fprintf(app.out, "%-24s %-12s %-16s %s\n", config.Name, states[config.Name], config.IP, config.Box)
	}
	return nil
}

func (app *App) action(action, name string, askConfirmation bool) error {
	if !validName.MatchString(name) {
		return errors.New("nome VM non valido")
	}
	config, err := loadConfig(app.configPath(name))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("VM %q non trovata", name)
		}
		return err
	}
	switch action {
	case "up":
		return app.up(config)
	case "connect":
		return app.connect(config)
	case "destroy":
		if askConfirmation {
			confirmed, err := app.confirm("Distruggere definitivamente "+config.Name+"?", false)
			if err != nil || !confirmed {
				return err
			}
		}
		return app.destroy(config)
	default:
		return errors.New("azione non supportata")
	}
}

func (app *App) up(config VMConfig) error {
	if err := app.writeVMAssets(config); err != nil {
		return err
	}
	return app.runVagrant(config, "up", "--provider=hyperv")
}

func (app *App) connect(config VMConfig) error {
	sshPath, keygenPath, err := openSSHTools()
	if err != nil {
		return err
	}
	vagrantKey := filepath.Join(app.vmDir(config.Name), ".vagrant", "machines", "default", "hyperv", "private_key")
	if _, err := os.Stat(vagrantKey); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errors.New("chiave Vagrant non trovata: eseguire prima Avvia / crea")
		}
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("impossibile determinare la home: %w", err)
	}
	keyDir := filepath.Join(home, ".ssh", "vagrant", config.Name)
	privateKey, err := prepareSSHKey(vagrantKey, keyDir, keygenPath)
	if err != nil {
		return err
	}
	command := exec.Command(sshPath, "-i", privateKey, "vagrant@"+config.IP)
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, app.out, app.errOut
	if err := command.Run(); err != nil {
		return fmt.Errorf("connessione SSH: %w", err)
	}
	return nil
}

func (app *App) destroy(config VMConfig) error {
	if _, err := os.Stat(filepath.Join(app.vmDir(config.Name), ".vagrant")); err == nil {
		if err := app.runVagrant(config, "destroy", "-f"); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := cleanupSSH(config); err != nil {
		return err
	}
	if err := os.RemoveAll(app.vmDir(config.Name)); err != nil {
		return fmt.Errorf("rimozione file VM: %w", err)
	}
	if err := os.Remove(app.configPath(config.Name)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("rimozione configurazione: %w", err)
	}
	fmt.Fprintf(app.out, "VM %s eliminata.\n", config.Name)
	return nil
}

func openSSHTools() (string, string, error) {
	windowsRoot := os.Getenv("WINDIR")
	for _, directory := range []string{
		filepath.Join(windowsRoot, "Sysnative", "OpenSSH"),
		filepath.Join(windowsRoot, "System32", "OpenSSH"),
	} {
		sshPath := filepath.Join(directory, "ssh.exe")
		keygenPath := filepath.Join(directory, "ssh-keygen.exe")
		if fileExists(sshPath) && fileExists(keygenPath) {
			return sshPath, keygenPath, nil
		}
	}
	sshPath, sshErr := exec.LookPath("ssh.exe")
	keygenPath, keygenErr := exec.LookPath("ssh-keygen.exe")
	if sshErr == nil && keygenErr == nil {
		return sshPath, keygenPath, nil
	}
	return "", "", errors.New("OpenSSH Client non installato")
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func prepareSSHKey(vagrantKey, keyDir, keygenPath string) (string, error) {
	if err := os.MkdirAll(keyDir, 0o700); err != nil {
		return "", fmt.Errorf("creazione directory chiave SSH: %w", err)
	}
	privateKey := filepath.Join(keyDir, "id_ed25519")
	publicKey := privateKey + ".pub"
	if !fileExists(privateKey) {
		content, err := os.ReadFile(vagrantKey)
		if err != nil {
			return "", fmt.Errorf("lettura chiave Vagrant: %w", err)
		}
		if err := os.WriteFile(privateKey, content, 0o600); err != nil {
			return "", fmt.Errorf("copia chiave Vagrant: %w", err)
		}
	}
	if !fileExists(publicKey) {
		command := exec.Command(keygenPath, "-y", "-f", privateKey)
		output, err := command.Output()
		if err != nil {
			return "", fmt.Errorf("generazione chiave pubblica: %w", err)
		}
		if err := os.WriteFile(publicKey, output, 0o644); err != nil {
			return "", fmt.Errorf("scrittura chiave pubblica: %w", err)
		}
	}
	return privateKey, nil
}

func cleanupSSH(config VMConfig) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("impossibile determinare la home: %w", err)
	}
	if err := os.RemoveAll(filepath.Join(home, ".ssh", "vagrant", config.Name)); err != nil {
		return fmt.Errorf("rimozione chiavi SSH: %w", err)
	}
	knownHosts := filepath.Join(home, ".ssh", "known_hosts")
	if !fileExists(knownHosts) {
		return nil
	}
	_, keygenPath, err := openSSHTools()
	if err == nil {
		_ = exec.Command(keygenPath, "-R", config.IP, "-f", knownHosts).Run()
		_ = os.Remove(knownHosts + ".old")
	}
	return nil
}

func (app *App) runVagrant(config VMConfig, args ...string) error {
	path, err := exec.LookPath("vagrant")
	if err != nil {
		return errors.New("Vagrant non trovato nel PATH")
	}
	command := exec.Command(path, args...)
	command.Dir = app.vmDir(config.Name)
	command.Env = append(os.Environ(), config.environment()...)
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, app.out, app.errOut
	if err := command.Run(); err != nil {
		return fmt.Errorf("vagrant %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

func (config VMConfig) environment() []string {
	return []string{
		"VM_NAME=" + config.Name, "VM_MEMORY=" + strconv.Itoa(config.Memory),
		"VM_MAX_MEMORY=" + strconv.Itoa(config.MaxMemory), "VM_CPUS=" + strconv.Itoa(config.CPUs),
		"VM_IP=" + config.IP, "VM_GATEWAY=" + config.Gateway, "VM_SWITCH=" + config.Switch,
		"VM_BOX=" + config.Box, "VM_BOX_VERSION=" + config.BoxVersion,
		"VM_BOX_ARCHITECTURE=" + config.BoxArchitecture, "VM_PROVISIONER=" + config.Provisioner,
		"VM_IP_TIMEOUT=" + strconv.Itoa(config.IPTimeout),
	}
}

func (app *App) vmStates(configs []VMConfig) map[string]string {
	states := make(map[string]string, len(configs))
	hasInitializedVM := false
	for _, config := range configs {
		if _, err := os.Stat(filepath.Join(app.vmDir(config.Name), ".vagrant")); errors.Is(err, os.ErrNotExist) {
			states[config.Name] = "non creata"
		} else {
			states[config.Name] = "sconosciuto"
			hasInitializedVM = true
		}
	}
	if !hasInitializedVM {
		return states
	}

	command := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Get-VM -ErrorAction SilentlyContinue | Select-Object Name,State | ConvertTo-Csv -NoTypeInformation")
	output, err := command.Output()
	if err != nil {
		return states
	}
	reader := csv.NewReader(strings.NewReader(string(output)))
	records, err := reader.ReadAll()
	if err != nil || len(records) < 2 {
		return states
	}
	for _, record := range records[1:] {
		if len(record) < 2 {
			continue
		}
		if _, tracked := states[record[0]]; tracked {
			states[record[0]] = strings.ToLower(record[1])
		}
	}
	return states
}
