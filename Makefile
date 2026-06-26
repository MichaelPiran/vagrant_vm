# RUN COMMAND WITH POWERSHELL ADMIN

VM_NAME=test-vm-5
VM_MEMORY=2048
VM_CPUS=2
VM_IP=192.168.0.10

.PHONY: new up destroy

new:
	@powershell -Command "\
		if (!(Test-Path '.\$(VM_NAME)')) { New-Item -ItemType Directory -Path '.\$(VM_NAME)' | Out-Null };\
		Copy-Item -Path '.\Vagrantfile' -Destination '.\$(VM_NAME)\Vagrantfile' -Force;\
		$$content = @('=======================================',\
		'   INFO VM',\
		'=======================================',\
		'Nome VM:    $(VM_NAME)',\
		'IP Statico: $(VM_IP)',\
		'RAM:        $(VM_MEMORY) MB',\
		'vCPU:       $(VM_CPUS)',\
		'Creato il:  $$(Get-Date -Format \"dd/MM/yyyy HH:mm:ss\")',\
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