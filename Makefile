# RUN COMMAND WITH POWERSHELL ADMIN

VM_NAME=debian12-vm
VM_MEMORY=2048
VM_CPUS=2
VM_IP=192.168.0.10
# VM_BOX=generic/ubuntu2204 
VM_BOX=generic/debian12
.PHONY: new up destroy list start

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
		$$env:VM_CPUS='$(VM_CPUS)';\
		$$env:VM_IP='$(VM_IP)';\
		cd '.\$(VM_NAME)';\
		vagrant up --provider=hyperv"

destroy:
	@powershell -Command "\
		if (Test-Path '.\$(VM_NAME)') {\
			cd '.\$(VM_NAME)';\
			vagrant destroy -f;\
			cd ..;\
			Remove-Item -Path '.\$(VM_NAME)' -Recurse -Force\
		}"

list:
	@powershell -Command "Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -Autosize"

VM_NAME_BOOT=test-vm-5
start:
	@powershell -Command "\
		if (Get-VM -Name '$(VM_NAME_BOOT)' -ErrorAction SilentlyContinue) {\
			Write-Host 'Starting VM: $(VM_NAME_BOOT)...' -ForegroundColor Cyan;\
			Start-VM -Name '$(VM_NAME_BOOT)';\
			Write-Host 'VM $(VM_NAME_BOOT) is now powering up.' -ForegroundColor Green;\
		} else {\
			Write-Host 'Error: VM \"$(VM_NAME_BOOT)\" does not exist on this Hyper-V host.' -ForegroundColor Red;\
			exit 1;\
		}"