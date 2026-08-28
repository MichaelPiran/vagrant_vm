BINARY := vmctl.exe
VM ?=
export VM

.PHONY: help fmt test build run list new up connect destroy clean require-vm

help:
	@echo Comandi disponibili:
	@echo   make fmt                 Formatta il codice Go
	@echo   make test                Esegue i test
	@echo   make build               Compila $(BINARY)
	@echo   make run                 Avvia il menu interattivo
	@echo   make list                Elenca le VM create
	@echo   make new                 Avvia la creazione guidata
	@echo   make up VM=nome          Crea o avvia una VM
	@echo   make connect VM=nome     Si connette a una VM via SSH
	@echo   make destroy VM=nome     Distrugge una VM
	@echo   make clean               Rimuove l'eseguibile compilato

fmt:
	go fmt ./...

test:
	go test ./...

build:
	go build -o $(BINARY) .

run: build
	.\$(BINARY)

list: build
	.\$(BINARY) list

new: build
	.\$(BINARY) new

up: require-vm build
	.\$(BINARY) up "$(VM)"

connect: require-vm build
	.\$(BINARY) connect "$(VM)"

destroy: require-vm build
	.\$(BINARY) destroy "$(VM)"

require-vm:
	@powershell -NoProfile -Command "if ([string]::IsNullOrWhiteSpace($$env:VM)) { Write-Error 'Specificare la VM con VM=nome'; exit 1 }"

clean:
	@powershell -NoProfile -Command "Remove-Item -Force '$(BINARY)' -ErrorAction SilentlyContinue"