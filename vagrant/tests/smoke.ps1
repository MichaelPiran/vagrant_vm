$ErrorActionPreference = 'Stop'
$legacy = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("vagrant-legacy-test-" + [guid]::NewGuid())
$oldRoot = $env:VM_ROOT
$oldName = $env:VM_NAME
$oldIp = $env:VM_IP
$oldMemory = $env:VM_MEMORY
$oldCpus = $env:VM_CPUS
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $env:VM_ROOT = $temp
    $env:VM_NAME = 'test-vm'
    $env:VM_IP = '192.0.2.10'
    $env:VM_MEMORY = '1024'
    $env:VM_CPUS = '2'
    & (Join-Path $legacy 'manage.ps1') new
    $vm = Join-Path $temp 'test-vm'
    foreach ($file in 'Vagrantfile', 'info.txt', 'provisioners\debian.sh', 'provisioners\alpine.sh') {
        if (-not (Test-Path -LiteralPath (Join-Path $vm $file))) { throw "File non creato: $file" }
    }
    if (-not (Select-String -LiteralPath (Join-Path $vm 'info.txt') -SimpleMatch '192.0.2.10' -Quiet)) {
        throw 'Il file info.txt non contiene l''IP configurato.'
    }
    $env:VM_NAME = ''
    try {
        & (Join-Path $legacy 'manage.ps1') new
        throw 'VM_NAME vuoto non rifiutato.'
    } catch {
        if ($_.Exception.Message -notmatch 'VM_NAME mancante') { throw }
    }
    function Get-VM {
        [pscustomobject]@{ Name = 'mock-vm'; State = 'Off'; CPUUsage = 0; MemoryAssigned = 0; Uptime = [timespan]::Zero }
    }
    if ((& (Join-Path $legacy 'manage.ps1') list | Out-String) -notmatch 'mock-vm') {
        throw 'list non mostra le VM Hyper-V.'
    }
    Push-Location $legacy
    try {
        & make -n list 'VM=vm-che-non-esiste' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'list richiede erroneamente una configurazione.' }
        $ErrorActionPreference = 'Continue'
        try {
            $output = & make -n new 'VM=vm-che-non-esiste' 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = 'Stop' }
        if ($exitCode -eq 0 -or "$output" -notmatch 'Configurazione') {
            throw 'new non rileva la configurazione mancante.'
        }
        & make new 'VM=example' 'CONFIG_DIR=configs' "VM_ROOT=$temp"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $temp 'example\info.txt'))) {
            throw 'make new non usa la configurazione e il percorso specificati.'
        }
    } finally { Pop-Location }
    Write-Host 'Test legacy superati.'
} finally {
    $env:VM_ROOT = $oldRoot
    $env:VM_NAME = $oldName
    $env:VM_IP = $oldIp
    $env:VM_MEMORY = $oldMemory
    $env:VM_CPUS = $oldCpus
    Remove-Item -LiteralPath $temp -Recurse -Force
}
