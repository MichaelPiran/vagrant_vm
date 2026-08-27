# RUN COMMAND WITH POWERSHELL ADMIN

-include local.mk
VM ?= debian12-vm
CONFIG_FILE := configs/$(VM).env

ifeq ($(wildcard $(CONFIG_FILE)),)
$(error Configurazione '$(CONFIG_FILE)' non trovata. Usa VM=<nome-config>)
endif

include $(CONFIG_FILE)

.PHONY: new up destroy list start connect

new:
	@powershell -Command "\
		if (!(Test-Path '.\$(VM_NAME)')) { New-Item -ItemType Directory -Path '.\$(VM_NAME)' | Out-Null };\
		Copy-Item -Path '.\Vagrantfile' -Destination '.\$(VM_NAME)\Vagrantfile' -Force;\
		$$date = (Get-Date -Format 'dd/MM/yyyy HH:mm:ss');\
		$$content = @('=======================================',\
		'   INFO VM',\
		'=======================================',\
		'Nome VM:    $(VM_NAME)',\
		'IP Statico: $(VM_IP)',\
		'RAM:        $(VM_MEMORY) MB',\
		'vCPU:       $(VM_CPUS)',\
		\"Creato il:   $$date\",\
		'=======================================');\
		$$content | Out-File -FilePath '.\$(VM_NAME)\info.txt' -Encoding utf8"

up:
	@powershell -Command "\
		$$env:VM_NAME='$(VM_NAME)';\
		$$env:VM_MEMORY='$(VM_MEMORY)';\
		$$env:VM_MAX_MEMORY='$(VM_MAX_MEMORY)';\
		$$env:VM_CPUS='$(VM_CPUS)';\
		$$env:VM_IP='$(VM_IP)';\
		$$env:VM_GATEWAY='$(VM_GATEWAY)';\
		$$env:VM_SWITCH='$(VM_SWITCH)';\
		$$env:VM_BOX='$(VM_BOX)';\
		cd '.\$(VM_NAME)';\
		vagrant up --provider=hyperv"

connect:
	@powershell -Command "\
		$$openSshDir = Join-Path $$env:WINDIR 'Sysnative\OpenSSH';\
		if (!(Test-Path $$openSshDir)) { $$openSshDir = Join-Path $$env:WINDIR 'System32\OpenSSH' };\
		$$ssh = Join-Path $$openSshDir 'ssh.exe';\
		$$sshKeygen = Join-Path $$openSshDir 'ssh-keygen.exe';\
		if (!(Test-Path $$ssh) -or !(Test-Path $$sshKeygen)) { Write-Error 'OpenSSH Client non installato'; exit 1 };\
		$$vagrantKey = '.\$(VM_NAME)\.vagrant\machines\default\hyperv\private_key';\
		if (!(Test-Path $$vagrantKey)) { Write-Error 'Chiave Vagrant non trovata. Eseguire prima make up'; exit 1 };\
		$$keyDir = Join-Path $$HOME '.ssh\vagrant\$(VM_NAME)';\
		$$privateKey = Join-Path $$keyDir 'id_ed25519';\
		$$publicKey = $$privateKey + '.pub';\
		New-Item -ItemType Directory -Path $$keyDir -Force | Out-Null;\
		if (!(Test-Path $$privateKey)) { Copy-Item $$vagrantKey $$privateKey };\
		if (!(Test-Path $$publicKey)) {\
			& $$sshKeygen -y -f $$privateKey | Set-Content $$publicKey -Encoding ascii;\
			if ($$LASTEXITCODE -ne 0) { exit $$LASTEXITCODE };\
		};\
		& $$ssh -i $$privateKey 'vagrant@$(VM_IP)'"

destroy:
	@powershell -Command "\
		if (Test-Path '.\$(VM_NAME)') {\
			cd '.\$(VM_NAME)';\
			vagrant destroy -f;\
			if ($$LASTEXITCODE -ne 0) { exit $$LASTEXITCODE };\
			cd ..;\
			Remove-Item -Path '.\$(VM_NAME)' -Recurse -Force\
		};\
		$$keyDir = Join-Path $$HOME '.ssh\vagrant\$(VM_NAME)';\
		if (Test-Path $$keyDir) { Remove-Item $$keyDir -Recurse -Force };\
		$$openSshDir = Join-Path $$env:WINDIR 'Sysnative\OpenSSH';\
		if (!(Test-Path $$openSshDir)) { $$openSshDir = Join-Path $$env:WINDIR 'System32\OpenSSH' };\
		$$sshKeygen = Join-Path $$openSshDir 'ssh-keygen.exe';\
		$$knownHosts = Join-Path $$HOME '.ssh\known_hosts';\
		if ((Test-Path $$sshKeygen) -and (Test-Path $$knownHosts)) {\
			& $$sshKeygen -R '$(VM_IP)' -f $$knownHosts | Out-Null;\
			if ($$LASTEXITCODE -ne 0) { exit $$LASTEXITCODE };\
			Remove-Item ($$knownHosts + '.old') -Force -ErrorAction SilentlyContinue\
		}"

list:
	@powershell -Command "Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -Autosize"

start:
	@powershell -Command "\
		if (Get-VM -Name '$(VM_NAME)' -ErrorAction SilentlyContinue) {\
			Write-Host 'Starting VM: $(VM_NAME)...' -ForegroundColor Cyan;\
			Start-VM -Name '$(VM_NAME)';\
			Write-Host 'VM $(VM_NAME) is now powering up.' -ForegroundColor Green;\
		} else {\
			Write-Host 'Error: VM \"$(VM_NAME)\" does not exist on this Hyper-V host.' -ForegroundColor Red;\
			exit 1;\
		}"