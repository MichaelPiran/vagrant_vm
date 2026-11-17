<#
.SYNOPSIS
Prototipo: crea e gestisce VM Hyper-V con cloud-init, senza Vagrant.

.DESCRIPTION
Senza argomenti apre il menu interattivo (frecce, Invio, Esc/Ctrl+C per uscire).

.EXAMPLE
hvctl
hvctl pull ubuntu26
hvctl new web1 -Image ubuntu26 -Ip 192.168.0.20 -Gateway 192.168.0.1
hvctl new debian12-vm -FromEnv ..\configs\debian12-vm.env
hvctl connect web1
hvctl destroy web1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'images', 'pull', 'new', 'up', 'stop', 'list', 'connect', 'console', 'destroy', 'help')]
    [string]$Command = 'menu',
    [Parameter(Position = 1)][string]$Name,
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
    [string]$User = 'dev',
    [string]$FromEnv,
    [int]$SshTimeoutSec = 180,
    [int]$Seconds = 0,
    [switch]$Start,
    [switch]$NoStart,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\CloudInit.ps1')
. (Join-Path $PSScriptRoot 'lib\Images.ps1')
. (Join-Path $PSScriptRoot 'lib\Network.ps1')
. (Join-Path $PSScriptRoot 'lib\Vm.ps1')
. (Join-Path $PSScriptRoot 'lib\Tui.ps1')

function Get-NewVmSettings {
    $settings = @{
        Name = $Name; Image = $Image; Ip = $Ip; Gateway = $Gateway; PrefixLength = $PrefixLength; Dns = $Dns
        VmSwitch = $VmSwitch; MemoryMB = $MemoryMB; MaxMemoryMB = $MaxMemoryMB; Cpus = $Cpus; DiskGB = $DiskGB; User = $User
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
            if (-not $PSBoundParameters.ContainsKey($key)) { $settings[$key] = $fromFile[$key] }
        }
    }
    if (-not $settings.Gateway) {
        $network = Get-SwitchNetwork $settings.VmSwitch
        if (-not $network) { throw "Impossibile rilevare il gateway dallo switch '$($settings.VmSwitch)': specificare -Gateway." }
        $settings.Gateway = $network.Gateway
        if (-not $PSBoundParameters.ContainsKey('PrefixLength')) { $settings.PrefixLength = $network.PrefixLength }
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
    if ($Command -in 'up', 'stop', 'connect', 'console', 'destroy') {
        if (-not $Name) { throw "Il comando '$Command' richiede il nome della VM." }
        Assert-VmName $Name
    }

    switch ($Command) {
        'menu'    { Start-Tui }
        'images'  { Show-Images }
        'pull'    { if ($Name) { Invoke-ImagePull -Id $Name -Force:$Force } else { Write-Host 'Specifica un''immagine. Disponibili:'; Show-Images } }
        'new' {
            if (-not $Name -and -not $FromEnv) { throw "Il comando 'new' richiede il nome della VM (o -FromEnv)." }
            $settings = Get-NewVmSettings
            New-HvVm -Settings $settings -NoStart:$NoStart -SshTimeoutSec $SshTimeoutSec
        }
        'up'      { Start-HvVm -Name $Name -SshTimeoutSec $SshTimeoutSec }
        'stop'    { Stop-HvVm -Name $Name -Force:$Force }
        'list'    { Show-Vms }
        'connect' { Connect-HvVm -Name $Name }
        'console' { Show-HvConsole -Name $Name -Seconds $Seconds -Start:$Start }
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
