package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExtractScriptsIsStableAndComplete(t *testing.T) {
	root := t.TempDir()
	first, err := extractScripts(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"hvctl.ps1", filepath.Join("lib", "Vm.ps1"), filepath.Join("lib", "Tui.ps1")} {
		if _, err := os.Stat(filepath.Join(first, name)); err != nil {
			t.Errorf("file estratto mancante %s: %v", name, err)
		}
	}
	second, err := extractScripts(root)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Errorf("la seconda estrazione usa un'altra cartella: %s != %s", first, second)
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 1 {
		t.Errorf("attesa una sola cartella in cache, trovate %d", len(entries))
	}
}
