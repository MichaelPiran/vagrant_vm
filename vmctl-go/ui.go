package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"

	"github.com/AlecAivazis/survey/v2"
)

const minimalSelectTemplate = `
{{- define "option"}}
		{{- if eq .SelectedIndex .CurrentIndex }}{{color "cyan+b"}}> {{else}}  {{end}}
		{{- .CurrentOpt.Value}}{{color "reset"}}
{{end}}
{{- color "cyan+b"}}{{ .Message }}{{ .FilterMessage }}{{color "reset"}}
{{- if .ShowAnswer}}  {{color "cyan"}}{{.Answer}}{{color "reset"}}{{"\n"}}
{{- else}}{{"\n"}}
	{{- range $ix, $option := .PageEntries}}
		{{- template "option" $.IterateOption $ix $option}}
	{{- end}}
{{- end}}`

func init() {
	survey.SelectQuestionTemplate = minimalSelectTemplate
}

func (app *App) run(args []string) error {
	if len(args) == 0 {
		return app.menu()
	}
	switch args[0] {
	case "help", "-h", "--help":
		fmt.Fprintln(app.out, usage)
		return nil
	case "home":
		fmt.Fprintln(app.out, app.home)
		return nil
	case "list":
		return app.printVMs()
	case "new":
		if len(args) != 1 {
			return errors.New("il comando new non accetta argomenti")
		}
		_, err := app.createVM()
		return err
	case "up", "connect", "destroy":
		if len(args) != 2 {
			return fmt.Errorf("uso: vmctl %s <nome>", args[0])
		}
		return app.action(args[0], args[1], true)
	default:
		return fmt.Errorf("comando sconosciuto %q\n\n%s", args[0], usage)
	}
}

func (app *App) menu() error {
	for {
		configs, err := app.loadAllConfigs()
		if err != nil {
			return err
		}
		states := app.vmStates(configs)
		options := make([]string, 0, len(configs)+2)
		for _, config := range configs {
			options = append(options, fmt.Sprintf("%-24s %s", config.Name, states[config.Name]))
		}
		options = append(options, "New", "Esci")
		selected, err := selectIndex("VM create", options)
		if err != nil {
			return err
		}
		switch selected {
		case len(configs):
			config, err := app.createVM()
			if err != nil {
				fmt.Fprintln(app.errOut, "Errore:", err)
				continue
			}
			if err := app.vmMenu(config); err != nil {
				fmt.Fprintln(app.errOut, "Errore:", err)
			}
		case len(configs) + 1:
			return nil
		default:
			if err := app.vmMenu(configs[selected]); err != nil {
				fmt.Fprintln(app.errOut, "Errore:", err)
			}
		}
	}
}

func (app *App) vmMenu(config VMConfig) error {
	for {
		state := app.vmStates([]VMConfig{config})[config.Name]
		selected, err := selectIndex(fmt.Sprintf("%s (%s)", config.Name, state), []string{
			"Avvia / crea",
			"Connetti via SSH",
			"Destroy",
			"Indietro",
		})
		if err != nil {
			return err
		}
		switch selected {
		case 0:
			if err := app.up(config); err != nil {
				fmt.Fprintln(app.errOut, "Errore:", err)
			}
		case 1:
			if err := app.connect(config); err != nil {
				fmt.Fprintln(app.errOut, "Errore:", err)
			}
		case 2:
			confirmed, err := app.confirm("Distruggere definitivamente "+config.Name+"?", false)
			if err != nil {
				return err
			}
			if confirmed {
				if err := app.destroy(config); err != nil {
					fmt.Fprintln(app.errOut, "Errore:", err)
					continue
				}
				return nil
			}
		case 3:
			return nil
		}
	}
}

func (app *App) createVM() (VMConfig, error) {
	options := make([]string, len(supportedImages))
	for index, image := range supportedImages {
		options[index] = fmt.Sprintf("%s (%s)", image.Name, image.Box)
	}
	selected, err := selectIndex("Immagine", options)
	if err != nil {
		return VMConfig{}, err
	}
	image := supportedImages[selected]
	defaults := VMConfig{Name: image.ID + "-vm", Memory: 1024, MaxMemory: 10240, CPUs: 2, IP: "192.168.0.10", Gateway: "192.168.0.1", Switch: "VMSwitchNat", Box: image.Box, BoxVersion: image.Version, BoxArchitecture: image.Architecture, Provisioner: image.Provisioner, IPTimeout: 120}
	config := defaults
	if config.Name, err = app.prompt("Nome VM", defaults.Name); err != nil {
		return VMConfig{}, err
	}
	if !validName.MatchString(config.Name) {
		return VMConfig{}, errors.New("il nome puo' contenere solo lettere, numeri, punto, trattino e underscore")
	}
	if _, err := os.Stat(app.configPath(config.Name)); err == nil {
		return VMConfig{}, fmt.Errorf("la VM %q esiste gia'", config.Name)
	} else if !errors.Is(err, os.ErrNotExist) {
		return VMConfig{}, err
	}
	if config.Memory, err = app.promptInt("Memoria iniziale (MB)", defaults.Memory, 128); err != nil {
		return VMConfig{}, err
	}
	if config.MaxMemory, err = app.promptInt("Memoria massima (MB)", defaults.MaxMemory, config.Memory); err != nil {
		return VMConfig{}, err
	}
	if config.CPUs, err = app.promptInt("vCPU", defaults.CPUs, 1); err != nil {
		return VMConfig{}, err
	}
	if config.IP, err = app.promptIP("IP statico", defaults.IP); err != nil {
		return VMConfig{}, err
	}
	if config.Gateway, err = app.promptIP("Gateway", defaults.Gateway); err != nil {
		return VMConfig{}, err
	}
	if config.Switch, err = app.prompt("Switch Hyper-V", defaults.Switch); err != nil {
		return VMConfig{}, err
	}
	if config.BoxVersion, err = app.prompt("Versione box", defaults.BoxVersion); err != nil {
		return VMConfig{}, err
	}
	if config.BoxArchitecture, err = app.prompt("Architettura box", defaults.BoxArchitecture); err != nil {
		return VMConfig{}, err
	}
	if config.IPTimeout, err = app.promptInt("Timeout IP (secondi)", defaults.IPTimeout, 1); err != nil {
		return VMConfig{}, err
	}
	if err := validateConfig(config); err != nil {
		return VMConfig{}, err
	}
	if err := app.saveConfig(config); err != nil {
		return VMConfig{}, err
	}
	if err := app.writeVMAssets(config); err != nil {
		_ = os.Remove(app.configPath(config.Name))
		_ = os.RemoveAll(app.vmDir(config.Name))
		return VMConfig{}, err
	}
	fmt.Fprintf(app.out, "VM %s creata. Configurazione: %s\n", config.Name, app.configPath(config.Name))
	return config, nil
}

func (app *App) prompt(label, defaultValue string) (string, error) {
	if defaultValue == "" {
		fmt.Fprintf(app.out, "%s: ", label)
	} else {
		fmt.Fprintf(app.out, "%s [%s]: ", label, defaultValue)
	}
	value, err := app.reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	value = strings.TrimSpace(value)
	if value == "" {
		value = defaultValue
	}
	if value == "" {
		return "", fmt.Errorf("%s e' obbligatorio", label)
	}
	return value, nil
}

func (app *App) promptInt(label string, defaultValue, minimum int) (int, error) {
	value, err := app.prompt(label, strconv.Itoa(defaultValue))
	if err != nil {
		return 0, err
	}
	number, err := strconv.Atoi(value)
	if err != nil || number < minimum {
		return 0, fmt.Errorf("%s deve essere un intero >= %d", label, minimum)
	}
	return number, nil
}

func (app *App) promptIP(label, defaultValue string) (string, error) {
	value, err := app.prompt(label, defaultValue)
	if err != nil {
		return "", err
	}
	if net.ParseIP(value) == nil {
		return "", fmt.Errorf("%s non e' un indirizzo IP valido", label)
	}
	return value, nil
}

func (app *App) confirm(label string, defaultValue bool) (bool, error) {
	options := []string{"No", "Si"}
	defaultOption := "No"
	if defaultValue {
		options = []string{"Si", "No"}
		defaultOption = "Si"
	}
	value := defaultOption
	err := survey.AskOne(&survey.Select{Message: label, Options: options, Default: defaultOption}, &value)
	if err != nil {
		return false, err
	}
	return value == "Si", nil
}

func selectIndex(message string, options []string) (int, error) {
	selected := 0
	prompt := &survey.Select{Message: message, Options: options, PageSize: 12}
	if err := survey.AskOne(prompt, &selected); err != nil {
		return 0, err
	}
	return selected, nil
}
