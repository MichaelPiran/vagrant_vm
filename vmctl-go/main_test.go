package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestConfigRoundTrip(t *testing.T) {
	app := &App{home: t.TempDir()}
	if err := app.ensureLayout(); err != nil {
		t.Fatal(err)
	}
	config := VMConfig{
		Name: "test-vm", Memory: 1024, MaxMemory: 4096, CPUs: 2,
		IP: "192.168.0.20", Gateway: "192.168.0.1", Switch: "VMSwitchNat",
		Box: "generic/ubuntu2204", BoxVersion: "4.3.12", BoxArchitecture: "amd64",
		Provisioner: "ubuntu", IPTimeout: 120,
	}
	if err := app.saveConfig(config); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadConfig(app.configPath(config.Name))
	if err != nil {
		t.Fatal(err)
	}
	if loaded != config {
		t.Fatalf("configurazione riletta diversa: %#v", loaded)
	}
}

func TestEnsureLayoutCreatesCatalog(t *testing.T) {
	app := &App{home: t.TempDir()}
	if err := app.ensureLayout(); err != nil {
		t.Fatal(err)
	}
	for _, image := range supportedImages {
		if _, err := os.Stat(filepath.Join(app.imagesDir(), image.ID+".env")); err != nil {
			t.Errorf("catalogo %s non creato: %v", image.ID, err)
		}
	}
}

func TestValidateConfigRejectsUnsupportedImage(t *testing.T) {
	config := VMConfig{
		Name: "test-vm", Memory: 1024, MaxMemory: 2048, CPUs: 1,
		IP: "192.168.0.20", Gateway: "192.168.0.1", Switch: "VMSwitchNat",
		Box: "other/linux", BoxVersion: "1", BoxArchitecture: "amd64",
		Provisioner: "other", IPTimeout: 120,
	}
	if err := validateConfig(config); err == nil {
		t.Fatal("immagine non supportata accettata")
	}
}

func TestValidateConfigAcceptsArch(t *testing.T) {
	config := VMConfig{
		Name: "arch-vm", Memory: 1024, MaxMemory: 2048, CPUs: 1,
		IP: "192.168.0.20", Gateway: "192.168.0.1", Switch: "VMSwitchNat",
		Box: "generic/arch", BoxVersion: "4.3.12", BoxArchitecture: "amd64",
		Provisioner: "arch", IPTimeout: 120,
	}
	if err := validateConfig(config); err != nil {
		t.Fatalf("configurazione Arch rifiutata: %v", err)
	}
}

func TestWriteVMAssetsCreatesArchProvisioner(t *testing.T) {
	app := &App{home: t.TempDir()}
	config := VMConfig{Name: "arch-vm", Box: "generic/arch"}

	if err := app.writeVMAssets(config); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(app.vmDir(config.Name), "provisioners", "arch.sh")); err != nil {
		t.Fatalf("provisioner Arch non creato: %v", err)
	}
}

func TestAlpineSupport(t *testing.T) {
	app := &App{home: t.TempDir()}
	config := VMConfig{
		Name: "alpine318-vm", Memory: 1024, MaxMemory: 2048, CPUs: 1,
		IP: "192.168.0.20", Gateway: "192.168.0.1", Switch: "VMSwitchNat",
		Box: "generic/alpine318", BoxVersion: "4.3.12", BoxArchitecture: "amd64",
		Provisioner: "alpine", IPTimeout: 120,
	}

	if err := validateConfig(config); err != nil {
		t.Fatalf("configurazione Alpine rifiutata: %v", err)
	}
	if err := app.writeVMAssets(config); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(app.vmDir(config.Name), "provisioners", "alpine.sh")); err != nil {
		t.Fatalf("provisioner Alpine non creato: %v", err)
	}
}

func TestVMStatesDoesNotQueryHyperVForUncreatedVM(t *testing.T) {
	app := &App{home: t.TempDir()}
	config := VMConfig{Name: "not-created"}

	states := app.vmStates([]VMConfig{config})

	if states[config.Name] != "non creata" {
		t.Fatalf("stato inatteso: %q", states[config.Name])
	}
}

func TestPrepareSSHKeyCopiesVagrantKey(t *testing.T) {
	directory := t.TempDir()
	vagrantKey := filepath.Join(directory, "vagrant_private_key")
	keyDir := filepath.Join(directory, "ssh")
	privateKey := filepath.Join(keyDir, "id_ed25519")
	if err := os.WriteFile(vagrantKey, []byte("private-key"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(keyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(privateKey+".pub", []byte("public-key"), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := prepareSSHKey(vagrantKey, keyDir, "unused-keygen")
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(result)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "private-key" {
		t.Fatalf("contenuto chiave inatteso: %q", content)
	}
}
