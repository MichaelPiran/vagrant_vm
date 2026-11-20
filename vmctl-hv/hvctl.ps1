<#
.SYNOPSIS
Prototipo: crea e gestisce VM Hyper-V con cloud-init, senza Vagrant.

.DESCRIPTION
Senza argomenti apre il menu interattivo (frecce, Invio, Esc/Ctrl+C per uscire).

.EXAMPLE
hvctl
hvctl pull ubuntu26
hvctl new web1 -User mario -Image ubuntu26 -Ip 192.168.0.20 -Gateway 192.168.0.1
hvctl new pc1 -User mario -Image ubuntu26 -Desktop        # chiede una password per il login grafico
hvctl new debian12-vm -User mario -FromEnv ..\configs\debian12-vm.env
hvctl connect web1
hvctl snapshot web1 prima-update
hvctl restore web1 prima-update
hvctl resize web1 -Cpus 4 -MemoryMB 2048 -DiskGB 40
hvctl destroy web1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'images', 'pull', 'new', 'up', 'stop', 'list', 'connect', 'console', 'resize', 'snapshot', 'snapshots', 'restore', 'destroy', 'help')]
    [string]$Command = 'menu',
    [Parameter(Position = 1)][string]$Name,
    [Parameter(Position = 2)][string]$SnapshotName,
    [string]$Image = 'ubuntu26',
    [string]$Ip,
    [string]$Gateway,
    [int]$PrefixLength = 24,
    [string[]]$Dns = @('1.1.1.1', '8.8.8.8'),
    [string]$VmSwitch = 'VMSwitchNat',
    [int]$MemoryMB = 1024,
    [int]$MaxMemoryMB = 4096,
    [int]$Cpus = 2,
    [int]$DiskGB = 20,
    [string]$User,
    [string]$Timezone = 'Europe/Rome',
    [string]$KeyboardLayout = 'it',
    [switch]$Password,
    [switch]$Desktop,
    [string]$FromEnv,
    [int]$SshTimeoutSec = 180,
    [int]$CloudInitTimeoutSec = 0,
    [int]$Seconds = 0,
    [switch]$Start,
    [switch]$NoStart,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:BoundParameters = $PSBoundParameters

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\CloudInit.ps1')
. (Join-Path $PSScriptRoot 'lib\Images.ps1')
. (Join-Path $PSScriptRoot 'lib\Network.ps1')
. (Join-Path $PSScriptRoot 'lib\Vm.ps1')
. (Join-Path $PSScriptRoot 'lib\Preflight.ps1')
. (Join-Path $PSScriptRoot 'lib\Tui.ps1')

function Get-NewVmSettings {
    $settings = @{
        Name = $Name; Image = $Image; Ip = $Ip; Gateway = $Gateway; PrefixLength = $PrefixLength; Dns = $Dns
        VmSwitch = $VmSwitch; MemoryMB = $MemoryMB; MaxMemoryMB = $MaxMemoryMB; Cpus = $Cpus; DiskGB = $DiskGB; User = $User
        Timezone = $Timezone; KeyboardLayout = $KeyboardLayout; Desktop = [bool]$Desktop
    }
    if ($FromEnv) {
        $legacy = ConvertFrom-EnvFile $FromEnv
        $box = $legacy['VM_BOX']
        if (-not $script:LegacyBoxMap.ContainsKey($box)) { throw "Il box '$box' non ha un'immagine cloud-init equivalente." }
        $fromFile = @{
            Name = $legacy['VM_NAME']; Image = $script:LegacyBoxMap[$box]; Ip = $legacy['VM_IP']; Gateway = $legacy['VM_GATEWAY']
            VmSwitch = $legacy['VM_SWITCH']; MemoryMB = [int]$legacy['VM_MEMORY']; MaxMemoryMB = [int]$legacy['VM_MAX_MEMORY']; Cpus = [int]$legacy['VM_CPUS']
        }
        foreach ($key in $fromFile.Keys) {
            if (-not $BoundParameters.ContainsKey($key)) { $settings[$key] = $fromFile[$key] }
        }
    } elseif ($Desktop) {
        # Un desktop richiede piu' risorse dei default di una VM server.
        if (-not $BoundParameters.ContainsKey('MemoryMB')) { $settings.MemoryMB = 2048 }
        if (-not $BoundParameters.ContainsKey('DiskGB')) { $settings.DiskGB = 30 }
        if (-not $BoundParameters.ContainsKey('MaxMemoryMB')) { $settings.MaxMemoryMB = [math]::Max(4096, $settings.MemoryMB) }
    }
    Assert-NewVmPrerequisites $settings
    if (-not $settings.Gateway) {
        $network = Get-SwitchNetwork $settings.VmSwitch
        if (-not $network) { throw "Impossibile rilevare il gateway dallo switch '$($settings.VmSwitch)': specificare -Gateway." }
        $settings.Gateway = $network.Gateway
        if (-not $BoundParameters.ContainsKey('PrefixLength')) { $settings.PrefixLength = $network.PrefixLength }
    }
    if (-not $settings.Ip) {
        $settings.Ip = Find-FreeIp -Gateway $settings.Gateway -PrefixLength $settings.PrefixLength
        Write-Host "IP statico assegnato: $($settings.Ip)"
    }
    return $settings
}

function Show-Images {
    $script:ImageCatalog.Keys | ForEach-Object {
        $downloaded = Test-Path -LiteralPath (Get-BaseImagePath $_)
        [pscustomobject]@{
            Id = $_; Nome = $script:ImageCatalog[$_].Name
            Stato = if ($downloaded) { 'scaricata' } else { 'da scaricare' }
            Comando = if ($downloaded) { '' } else { "hvctl pull $_" }
        }
    } | Format-Table -AutoSize
}

function Show-Vms {
    $configs = @(Get-AllVmConfigs)
    if ($configs.Count -eq 0) { Write-Host 'Nessuna VM creata.'; return }
    $states = Get-VmStates
    $configs | ForEach-Object {
        $state = if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { 'assente' }
        [pscustomobject]@{ Nome = $_.Name; Stato = $state; Ip = $_.Ip; Immagine = $_.Image; Cpu = $_.Cpus; RamMB = $_.MemoryMB; DiscoGB = $_.DiskGB }
    } | Format-Table -AutoSize
}

try {
    if ($Command -in 'up', 'stop', 'connect', 'console', 'resize', 'snapshot', 'snapshots', 'restore', 'destroy') {
        if (-not $Name) { throw "Il comando '$Command' richiede il nome della VM." }
        Assert-VmName $Name
    }
    Assert-Prerequisites $Command

    switch ($Command) {
        'menu'    { Start-Tui }
        'images'  { Show-Images }
        'pull'    { if ($Name) { Invoke-ImagePull -Id $Name -Force:$Force } else { Write-Host 'Specifica un''immagine. Disponibili:'; Show-Images } }
        'new' {
            if (-not $Name -and -not $FromEnv) { throw "Il comando 'new' richiede il nome della VM (o -FromEnv)." }
            Assert-GuestUser $User
            Assert-Timezone $Timezone
            Assert-KeyboardLayout $KeyboardLayout
            $passwordHash = if ($Password -or $Desktop) { Read-ConsolePasswordHash } else { $null }
            # Scelta dell'IP e creazione sotto lo stesso lock, cosi' due `new` in parallelo non ottengono lo stesso IP.
            $created = Use-HvLock {
                $settings = Get-NewVmSettings
                $settings.PasswordHash = $passwordHash
                New-HvVm -Settings $settings -NoStart
                $settings.Name
            }
            if (-not $NoStart) { Start-HvVm -Name ([string]($created | Select-Object -Last 1)) -SshTimeoutSec $SshTimeoutSec -CloudInitTimeoutSec $CloudInitTimeoutSec }
        }
        'up'      { Start-HvVm -Name $Name -SshTimeoutSec $SshTimeoutSec -CloudInitTimeoutSec $CloudInitTimeoutSec }
        'stop'    { Stop-HvVm -Name $Name -Force:$Force }
        'list'    { Show-Vms }
        'connect' { Connect-HvVm -Name $Name }
        'console' { Show-HvConsole -Name $Name -Seconds $Seconds -Start:$Start }
        'resize' {
            $changes = @{}
            foreach ($key in 'Cpus', 'MemoryMB', 'MaxMemoryMB', 'DiskGB') {
                if ($BoundParameters.ContainsKey($key)) { $changes[$key] = $PSBoundParameters[$key] }
            }
            Set-HvVmResources -Name $Name -Changes $changes
        }
        'snapshot'  { New-HvSnapshot -Name $Name -SnapshotName $SnapshotName }
        'snapshots' { Show-HvSnapshots -Name $Name }
        'restore' {
            $label = if ($SnapshotName) { "lo snapshot '$SnapshotName'" } else { "l'ultimo snapshot" }
            if ($Force -or (Read-Host "Ripristinare $label di '$Name'? Le modifiche successive andranno perse. [s/N]") -match '^[sSyY]') {
                Restore-HvSnapshot -Name $Name -SnapshotName $SnapshotName
            }
        }
        'destroy' {
            Read-VmConfig $Name | Out-Null
            if ($Force -or (Read-Host "Distruggere definitivamente '$Name'? [s/N]") -match '^[sSyY]') { Remove-HvVm -Name $Name }
        }
        default   { Get-Help $PSCommandPath -Full | Out-String | Write-Host }
    }
} catch {
    Write-Host "Errore: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
