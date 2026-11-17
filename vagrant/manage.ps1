param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('new', 'up', 'connect', 'destroy', 'list', 'start')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $env:VM_ROOT).Path
if ($Action -ne 'list') {
    if ([string]::IsNullOrWhiteSpace($env:VM_NAME)) { throw 'VM_NAME mancante nella configurazione.' }
    $vmDir = Join-Path $root $env:VM_NAME
}

function Get-OpenSshPath {
    param([string]$Name)
    $dir = Join-Path $env:WINDIR 'Sysnative\OpenSSH'
    if (-not (Test-Path $dir)) { $dir = Join-Path $env:WINDIR 'System32\OpenSSH' }
    return Join-Path $dir $Name
}

function New-VagrantFiles {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
    $provisioners = Join-Path $vmDir 'provisioners'
    New-Item -ItemType Directory -Path $provisioners -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Vagrantfile') -Destination $vmDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'provisioners\*') -Destination $provisioners -Recurse -Force
    $date = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
    @(
        '=======================================',
        '   INFO VM',
        '=======================================',
        "Nome VM:    $env:VM_NAME",
        "IP Statico: $env:VM_IP",
        "RAM:        $env:VM_MEMORY MB",
        "vCPU:       $env:VM_CPUS",
        "Creato il:   $date",
        '======================================='
    ) | Out-File -FilePath (Join-Path $vmDir 'info.txt') -Encoding utf8
}

switch ($Action) {
    'new' { New-VagrantFiles }
    'up' {
        New-VagrantFiles
        Push-Location $vmDir
        try {
            & vagrant up --provider=hyperv
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
    }
    'connect' {
        $ssh = Get-OpenSshPath 'ssh.exe'
        $sshKeygen = Get-OpenSshPath 'ssh-keygen.exe'
        if (-not (Test-Path $ssh) -or -not (Test-Path $sshKeygen)) { throw 'OpenSSH Client non installato' }
        $vagrantKey = Join-Path $vmDir '.vagrant\machines\default\hyperv\private_key'
        if (-not (Test-Path $vagrantKey)) { throw 'Chiave Vagrant non trovata. Eseguire prima make up' }
        $keyDir = Join-Path $HOME ".ssh\vagrant\$env:VM_NAME"
        $privateKey = Join-Path $keyDir 'id_ed25519'
        $publicKey = $privateKey + '.pub'
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        if (-not (Test-Path $privateKey)) { Copy-Item $vagrantKey $privateKey }
        if (-not (Test-Path $publicKey)) {
            $publicKeyContent = & $sshKeygen -y -f $privateKey
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            $publicKeyContent | Set-Content $publicKey -Encoding ascii
        }
        & $ssh -i $privateKey "vagrant@$env:VM_IP"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    'destroy' {
        if (Test-Path $vmDir) {
            Push-Location $vmDir
            try {
                & vagrant destroy -f
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            } finally { Pop-Location }
            Remove-Item -LiteralPath $vmDir -Recurse -Force
        }
        $keyDir = Join-Path $HOME ".ssh\vagrant\$env:VM_NAME"
        if (Test-Path $keyDir) { Remove-Item -LiteralPath $keyDir -Recurse -Force }
        $sshKeygen = Get-OpenSshPath 'ssh-keygen.exe'
        $knownHosts = Join-Path $HOME '.ssh\known_hosts'
        if ((Test-Path $sshKeygen) -and (Test-Path $knownHosts)) {
            & $sshKeygen -R $env:VM_IP -f $knownHosts 2>$null | Out-Null
            Remove-Item ($knownHosts + '.old') -Force -ErrorAction SilentlyContinue
        }
    }
    'list' { Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -Autosize }
    'start' {
        if (-not (Get-VM -Name $env:VM_NAME -ErrorAction SilentlyContinue)) {
            throw "VM '$env:VM_NAME' non presente su questo host Hyper-V."
        }
        Write-Host "Starting VM: $env:VM_NAME..." -ForegroundColor Cyan
        Start-VM -Name $env:VM_NAME
        Write-Host "VM $env:VM_NAME is now powering up." -ForegroundColor Green
    }
}
