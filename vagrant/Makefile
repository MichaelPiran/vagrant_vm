# Run from an elevated PowerShell in this directory.
-include ../local.mk
-include local.mk

VM ?= debian12-vm
CONFIG_DIR ?= ../configs
VM_ROOT ?= ..
CONFIG_FILE := $(CONFIG_DIR)/$(VM).env
-include $(CONFIG_FILE)
VM_IP_TIMEOUT ?= 120

export VM_NAME VM_MEMORY VM_MAX_MEMORY VM_CPUS VM_IP VM_GATEWAY VM_SWITCH
export VM_BOX VM_BOX_VERSION VM_BOX_ARCHITECTURE VM_PROVISIONER VM_IP_TIMEOUT VM_ROOT

.PHONY: help test new up destroy list start connect require-config

help:
	@echo Comandi: new up connect start destroy list test
	@echo Esempio: make up VM=debian12-vm

test:
	@powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1

require-config:
ifeq ($(wildcard $(CONFIG_FILE)),)
	$(error Configurazione '$(CONFIG_FILE)' non trovata. Usa VM=nome o CONFIG_DIR=percorso)
endif

new up connect start destroy: require-config
new up connect start destroy list:
	@powershell -NoProfile -ExecutionPolicy Bypass -File .\manage.ps1 $@
