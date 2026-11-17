// hvctl.exe incorpora gli script PowerShell e li esegue con Windows PowerShell,
// cosi' l'eseguibile si puo' copiare in qualsiasi cartella.
package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
)

//go:embed hvctl.ps1 lib/*.ps1
var scripts embed.FS

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	root, err := cacheRoot()
	if err != nil {
		return fail(err)
	}
	dir, err := extractScripts(root)
	if err != nil {
		return fail(err)
	}
	powershell, err := findPowerShell()
	if err != nil {
		return fail(err)
	}

	command := exec.Command(powershell, append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(dir, "hvctl.ps1")}, args...)...)
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr

	// Ctrl+C e' destinato al processo figlio (condivide la console): il launcher resta in attesa.
	signal.Ignore(os.Interrupt)
	if err := command.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode()
		}
		return fail(err)
	}
	return 0
}

func fail(err error) int {
	fmt.Fprintln(os.Stderr, "Errore:", err)
	return 1
}

func cacheRoot() (string, error) {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		var err error
		if base, err = os.UserCacheDir(); err != nil {
			return "", fmt.Errorf("impossibile determinare la cartella cache: %w", err)
		}
	}
	return filepath.Join(base, "hvctl", "scripts"), nil
}

// extractScripts scrive gli script in <root>\<hash>; una nuova versione dell'eseguibile usa una cartella diversa.
func extractScripts(root string) (string, error) {
	hash := sha256.New()
	var names []string
	err := fs.WalkDir(scripts, ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		content, err := scripts.ReadFile(path)
		if err != nil {
			return err
		}
		hash.Write([]byte(path))
		hash.Write(content)
		names = append(names, path)
		return nil
	})
	if err != nil {
		return "", err
	}
	target := filepath.Join(root, hex.EncodeToString(hash.Sum(nil))[:16])
	if _, err := os.Stat(filepath.Join(target, "hvctl.ps1")); err == nil {
		return target, nil
	}

	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fmt.Errorf("creazione %s: %w", root, err)
	}
	temporary, err := os.MkdirTemp(root, "extract-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temporary)
	for _, name := range names {
		content, err := scripts.ReadFile(name)
		if err != nil {
			return "", err
		}
		destination := filepath.Join(temporary, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(destination, content, 0o644); err != nil {
			return "", fmt.Errorf("scrittura %s: %w", destination, err)
		}
	}
	if err := os.Rename(temporary, target); err != nil {
		// Un altro processo puo' aver estratto la stessa versione nel frattempo.
		if _, statErr := os.Stat(filepath.Join(target, "hvctl.ps1")); statErr != nil {
			return "", fmt.Errorf("estrazione script: %w", err)
		}
	}
	return target, nil
}

func findPowerShell() (string, error) {
	windowsRoot := os.Getenv("WINDIR")
	if windowsRoot != "" {
		path := filepath.Join(windowsRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}
	path, err := exec.LookPath("powershell.exe")
	if err != nil {
		return "", errors.New("Windows PowerShell non trovato")
	}
	return path, nil
}
