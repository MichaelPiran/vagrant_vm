Set-StrictMode -Version 2.0

# Immagini cloud ufficiali con cloud-init. Debian 9 e Alpine 3.18 non sono
# incluse: non esiste un'immagine cloud-init affidabile per Hyper-V.
$script:ImageCatalog = [ordered]@{
    ubuntu26 = @{ Name = 'Ubuntu 26.04'; Url = 'https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img'
        Desktop = @{ Packages = @('ubuntu-desktop-minimal', 'xrdp'); RunCmd = @('systemctl set-default graphical.target') } }
    debian12 = @{ Name = 'Debian 12';    Url = 'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2'
        Desktop = @{ Packages = @('task-xfce-desktop', 'xrdp'); RunCmd = @('systemctl set-default graphical.target') } }
    arch     = @{ Name = 'Arch Linux';   Url = 'https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2'
        Desktop = @{ Packages = @('xorg-server', 'xfce4', 'lightdm', 'lightdm-gtk-greeter'); RunCmd = @('systemctl enable lightdm.service', 'systemctl set-default graphical.target') } }
}

# Mappa i box Vagrant dei vecchi file configs\*.env sulle nuove immagini.
$script:LegacyBoxMap = @{
    'generic/debian12'   = 'debian12'
    'generic/arch'       = 'arch'
}

# Hostname Linux valido (RFC 1123): max 63 caratteri, niente '-' iniziale o finale.
$script:ValidName = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

# Versione dello schema di vm.json: aumentare e aggiungere i default in Update-VmConfigObject quando si aggiungono campi.
$script:VmConfigVersion = 1
$script:VmConfigDefaults = [ordered]@{ Timezone = ''; KeyboardLayout = ''; ConsolePassword = $false; Desktop = $false }

$script:DefaultTimezone = 'Europe/Rome'
$script:DefaultKeyboardLayout = 'it'

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
        throw "Nome VM non valido '$Name': usa lettere, numeri e '-' (max 63 caratteri, senza '-' iniziale o finale)."
    }
}

function Assert-Timezone {
    param([string]$Timezone)
    if ($Timezone -cnotmatch '\A[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*\z') { throw "Fuso orario non valido '$Timezone' (esempio: Europe/Rome)." }
}

function Assert-KeyboardLayout {
    param([string]$Layout)
    if ($Layout -cnotmatch '\A[a-z][a-z0-9_-]{0,15}\z') { throw "Layout tastiera non valido '$Layout' (esempio: it)." }
}

# Lock globale (mutex) che serializza assegnazione IP e creazione delle VM tra processi hvctl; e' rientrante nello stesso thread.
function Use-HvLock {
    param([scriptblock]$Action, [int]$TimeoutSec = 600)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\hvctl-lock')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Un'altra istanza di hvctl sta creando o eliminando una VM (attesa scaduta dopo $TimeoutSec s)." }
        & $Action
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Chiede due volte la password per il login da console Hyper-V e restituisce solo l'hash SHA-512 crypt.
function Read-ConsolePasswordHash {
    $first = Read-Host 'Password per il login da console Hyper-V (min. 8 caratteri)' -AsSecureString
    $second = Read-Host 'Ripeti la password' -AsSecureString
    $plain = [System.Net.NetworkCredential]::new('', $first).Password
    if ($plain -ne [System.Net.NetworkCredential]::new('', $second).Password) { throw 'Le password non coincidono.' }
    if ($plain.Length -lt 8) { throw 'La password deve avere almeno 8 caratteri.' }
    return (ConvertTo-PasswordHash -Password $plain)
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

# Porta in memoria un vm.json di una versione precedente allo schema corrente (il file viene riscritto al primo salvataggio).
function Update-VmConfigObject {
    param($Config)
    foreach ($key in $script:VmConfigDefaults.Keys) {
        if (-not $Config.PSObject.Properties[$key]) { Add-Member -InputObject $Config -NotePropertyName $key -NotePropertyValue $script:VmConfigDefaults[$key] }
    }
    if (-not $Config.PSObject.Properties['Version']) { Add-Member -InputObject $Config -NotePropertyName Version -NotePropertyValue 0 }
    $Config.Version = $script:VmConfigVersion
    return $Config
}

function Save-VmConfig {
    param($Config)
    $Config.Version = $script:VmConfigVersion
    $Config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-VmDir $Config.Name) 'vm.json') -Encoding UTF8
}

function Read-VmConfigFile {
    param([string]$Path)
    return (Update-VmConfigObject (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json))
}

function Read-VmConfig {
    param([string]$Name)
    $path = Join-Path (Get-VmDir $Name) 'vm.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "VM '$Name' non trovata." }
    return (Read-VmConfigFile $path)
}

function Get-AllVmConfigs {
    $root = Join-Path (Get-HvHome) 'vms'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $configs = @(foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        $file = Join-Path $dir.FullName 'vm.json'
        if (Test-Path -LiteralPath $file) { Read-VmConfigFile $file }
    })
    return $configs
}
