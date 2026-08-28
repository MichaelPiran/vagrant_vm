package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const usage = `vmctl - gestione VM Vagrant/Hyper-V

Uso:
  vmctl                 apre il menu interattivo
  vmctl list            elenca le VM create
  vmctl new             crea una VM con procedura guidata
  vmctl up <nome>       crea o avvia una VM
  vmctl connect <nome>  apre una sessione SSH
  vmctl destroy <nome>  distrugge la VM e i relativi file
  vmctl home            mostra la directory dei dati

La directory predefinita e' ~/.vagrant-vm; VMCTL_HOME permette di cambiarla.`

type App struct {
	home   string
	reader *bufio.Reader
	out    io.Writer
	errOut io.Writer
}

func dataHome() (string, error) {
	if configured := os.Getenv("VMCTL_HOME"); configured != "" {
		return filepath.Abs(configured)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("impossibile determinare la home: %w", err)
	}
	return filepath.Join(home, ".vagrant-vm"), nil
}

func main() {
	home, err := dataHome()
	if err != nil {
		fatal(err)
	}
	app := &App{home: home, reader: bufio.NewReader(os.Stdin), out: os.Stdout, errOut: os.Stderr}
	if err := app.ensureLayout(); err != nil {
		fatal(err)
	}
	if err := app.run(os.Args[1:]); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "Errore:", err)
	os.Exit(1)
}
