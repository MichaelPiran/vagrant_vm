Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')
. (Join-Path $PSScriptRoot '..\lib\CloudInit.ps1')

$failures = 0
function Assert-True($Condition, $Message) {
    if ($Condition) { Write-Host "OK   $Message" } else { Write-Host "FAIL $Message" -ForegroundColor Red; $script:failures++ }
}

$mac = New-MacAddress 'web1'
Assert-True ($mac -match '^00155D[0-9A-F]{6}$') "MAC statico Hyper-V: $mac"
Assert-True ((New-MacAddress 'web1') -eq $mac) 'MAC deterministico'
Assert-True ((Format-Mac $mac) -match '^00:15:5d(:[0-9a-f]{2}){3}$') 'MAC formattato per cloud-init'

$network = New-NetworkConfig -Mac (Format-Mac $mac) -Ip 192.168.0.20 -PrefixLength 24 -Gateway 192.168.0.1 -Dns @('1.1.1.1', '8.8.8.8')
Assert-True ($network -match '192\.168\.0\.20/24' -and $network -match 'via: 192\.168\.0\.1' -and $network -match '- 8\.8\.8\.8') 'network-config'

$envFile = Join-Path ([IO.Path]::GetTempPath()) 'hvctl-test.env'
Set-Content -LiteralPath $envFile -Value "# commento`nVM_NAME=debian12-vm`nVM_BOX=generic/debian12`n"
$parsed = ConvertFrom-EnvFile $envFile
Remove-Item -LiteralPath $envFile
Assert-True ($parsed['VM_NAME'] -eq 'debian12-vm' -and $script:LegacyBoxMap[$parsed['VM_BOX']] -eq 'debian12') 'parsing .env legacy'

$iso = Join-Path ([IO.Path]::GetTempPath()) 'hvctl-test-seed.iso'
try {
    New-SeedIso -IsoPath $iso -Name web1 -User test_user -PublicKey 'ssh-ed25519 AAAA test' -Mac $mac -Ip 192.168.0.20 -PrefixLength 24 -Gateway 192.168.0.1 -Dns @('1.1.1.1')
    $bytes = [IO.File]::ReadAllBytes($iso)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $joliet = [Text.Encoding]::BigEndianUnicode.GetString($bytes) + [Text.Encoding]::BigEndianUnicode.GetString($bytes, 1, $bytes.Length - 2)
    Assert-True ($bytes.Length -gt 32768 -and $ascii.Substring(32769, 5) -eq 'CD001') 'ISO9660 valido'
    Assert-True ($ascii -match '(?i)cidata' -or $joliet -match '(?i)cidata') 'etichetta cidata'
    foreach ($file in 'user-data', 'meta-data', 'network-config') {
        Assert-True ($joliet.Contains($file)) "$file presente (Joliet)"
    }
    Assert-True ($ascii.Contains('#cloud-config') -and $ascii.Contains('ssh-ed25519 AAAA test')) 'contenuto user-data'
    Assert-True ($ascii.Contains("name: 'test_user'")) 'utente scelto presente nel seed'
} finally {
    Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot '..\lib\Tui.ps1')
$script:keys = New-Object System.Collections.Generic.Queue[string]
function Read-MenuKey { return [pscustomobject]@{ Key = $script:keys.Dequeue() } }
$menuAvailable = $true
if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $menuAvailable = $false }
if ($menuAvailable) {
    'DownArrow', 'DownArrow', 'UpArrow', 'Enter' | ForEach-Object { $script:keys.Enqueue($_) }
    $result = Select-Menu 'Test' @('a', 'b', 'c')
    Assert-True ($result -eq 1) 'menu: frecce + Invio selezionano la voce corretta'
    $script:keys.Enqueue('Escape')
    Assert-True ((Select-Menu 'Test' @('a', 'b')) -eq -1) 'menu: Esc annulla'
} else {
    Write-Host 'SKIP test menu (serve una console interattiva non rediretta)'
}
if ($failures -gt 0) { exit 1 }
Write-Host 'Tutti i test superati.'
