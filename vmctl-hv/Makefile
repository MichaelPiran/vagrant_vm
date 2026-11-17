BINARY := hvctl.exe

.PHONY: help build test smoke fmt clean

help:
	@echo Comandi disponibili:
	@echo   make build   Compila $(BINARY) (autonomo: contiene gli script PowerShell)
	@echo   make test    Test Go del launcher e smoke test degli script
	@echo   make fmt     Formatta il codice Go
	@echo   make clean   Rimuove l'eseguibile compilato

build:
	go build -trimpath -ldflags "-s -w" -o $(BINARY) .

fmt:
	go fmt ./...

test: smoke
	go test ./...

smoke:
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1

clean:
	@powershell -NoProfile -Command "Remove-Item -Force '$(BINARY)' -ErrorAction SilentlyContinue"
