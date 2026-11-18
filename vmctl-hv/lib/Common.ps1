Set-StrictMode -Version 2.0

# Immagini cloud ufficiali con cloud-init. Debian 9 e Alpine 3.18 non sono
# incluse: non esiste un'immagine cloud-init affidabile per Hyper-V.
$script:ImageCatalog = [ordered]@{
    ubuntu26 = @{ Name = 'Ubuntu 26.04'; Url = 'https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img' }
    debian12 = @{ Name = 'Debian 12';    Url = 'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2' }
    arch     = @{ Name = 'Arch Linux';   Url = 'https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2' }
}

# Mappa i box Vagrant dei vecchi file configs\*.env sulle nuove immagini.
$script:LegacyBoxMap = @{
    'generic/debian12'   = 'debian12'
    'generic/arch'       = 'arch'
}

$script:ValidName = '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$'

function Get-HvHome {
    if ($env:HVCTL_HOME) { return $env:HVCTL_HOME }
    return (Join-Path $env:USERPROFILE '.hvctl')
}

function Get-VmDir { param([string]$Name) Join-Path (Join-Path (Get-HvHome) 'vms') $Name }

function Get-ImagesDir { Join-Path (Get-HvHome) 'images' }

function Assert-GuestUser {
    param([string]$User)
    if ([string]::IsNullOrWhiteSpace($User)) { throw 'Specificare il nome utente Linux (-User).' }
    if ($User -cnotmatch '\A[a-z_][a-z0-9_-]{0,31}\z') {
        throw 'Nome utente Linux non valido: usare da 1 a 32 lettere minuscole, cifre, trattini o underscore, iniziando con una lettera o un underscore.'
    }
}

function Assert-VmName {
    param([string]$Name)
    if ($Name -notmatch $script:ValidName) {
        throw "Nome VM non valido '$Name': usa lettere, numeri e '-' (max 15 caratteri, valido anche come hostname NetBIOS)."
    }
}

function ConvertFrom-EnvFile {
    param([string]$Path)
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $key, $value = $line -split '=', 2
        if ($null -eq $value) { throw "Riga non valida in ${Path}: '$line'" }
        $values[$key.Trim()] = $value.Trim()
    }
    return $values
}

# MAC statico deterministico (prefisso Hyper-V 00:15:5D) per riconoscere la NIC in cloud-init.
function New-MacAddress {
    param([string]$Name)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name)) } finally { $sha.Dispose() }
    return ('00155D{0:X2}{1:X2}{2:X2}' -f $hash[0], $hash[1], $hash[2])
}

function Format-Mac {
    param([string]$Mac)
    return (($Mac -replace '(..)(?=.)', '$1:')).ToLower()
}

function Read-VmConfig {
    param([string]$Name)
    $path = Join-Path (Get-VmDir $Name) 'vm.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "VM '$Name' non trovata." }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-AllVmConfigs {
    $root = Join-Path (Get-HvHome) 'vms'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $configs = @(foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        $file = Join-Path $dir.FullName 'vm.json'
        if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
    })
    return $configs
}
