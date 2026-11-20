Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')
. (Join-Path $PSScriptRoot '..\lib\CloudInit.ps1')
. (Join-Path $PSScriptRoot '..\lib\Images.ps1')
. (Join-Path $PSScriptRoot '..\lib\Network.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vm.ps1')
. (Join-Path $PSScriptRoot '..\lib\Preflight.ps1')

$failures = 0
function Assert-True($Condition, $Message) {
    if ($Condition) { Write-Host "OK   $Message" } else { Write-Host "FAIL $Message" -ForegroundColor Red; $script:failures++ }
}
function Assert-Throws([scriptblock]$Action, $Pattern, $Message) {
    $thrown = $null
    try { & $Action } catch { $thrown = $_.Exception.Message }
    Assert-True ($null -ne $thrown -and $thrown -match $Pattern) $Message
}

# --- nome VM, fuso orario, tastiera ---
Assert-True ($null -eq (Assert-VmName ('a' * 63))) 'nome VM: 63 caratteri ammessi'
Assert-Throws { Assert-VmName ('a' * 64) } 'non valido' 'nome VM: 64 caratteri rifiutati'
Assert-Throws { Assert-VmName 'web-' } 'non valido' "nome VM: '-' finale rifiutato"
Assert-Throws { Assert-VmName '-web' } 'non valido' "nome VM: '-' iniziale rifiutato"
Assert-Throws { Assert-Timezone "Europe/Rome`nruncmd: x" } 'non valido' 'fuso orario con newline rifiutato'
Assert-Throws { Assert-KeyboardLayout 'it; rm' } 'non valido' 'layout tastiera con caratteri speciali rifiutato'
Assert-True ($null -eq (Assert-Timezone 'America/Argentina/Buenos_Aires')) 'fuso orario con piu livelli ammesso'

# --- cloud-init: fuso orario e tastiera italiani, password, desktop ---
$data = (New-UserData -Name web1 -User mario -PublicKey 'ssh-ed25519 AAAA test') -replace "`r`n", "`n"
Assert-True ($data -match 'timezone: Europe/Rome' -and $data -match '(?m)^keyboard:\n  layout: it$') 'user-data: fuso orario e tastiera italiani di default'
Assert-True ($data -match 'lock_passwd: true' -and $data -notmatch '(?m)^\s+passwd:' -and $data -notmatch 'packages:') 'user-data: senza password ne desktop'
$hash = ConvertTo-PasswordHash -Password 'Hello world!' -Salt 'saltstring'
Assert-True ($hash -eq '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1') 'hash SHA-512 crypt: vettore di test ufficiale'
Assert-True ((ConvertTo-PasswordHash -Password 'x') -match '^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$') 'hash SHA-512 crypt: formato con salt casuale'
$data = (New-UserData -Name pc1 -User mario -PublicKey 'k' -Timezone 'Europe/London' -KeyboardLayout 'gb' -PasswordHash $hash -Packages @('xrdp', 'xfce4') -RunCmd @('systemctl set-default graphical.target')) -replace "`r`n", "`n"
Assert-True ($data -match 'timezone: Europe/London' -and $data -match 'layout: gb') 'user-data: fuso orario e tastiera personalizzabili'
Assert-True ($data -match 'lock_passwd: false' -and $data.Contains("passwd: '$hash'")) 'user-data: password impostata, account sbloccato'
Assert-True ($data -match 'ssh_pwauth: false') 'user-data: SSH resta con sola chiave anche con password'
Assert-True ($data -match '(?m)^packages:\n  - xrdp\n  - xfce4$' -and $data -match '(?m)^runcmd:\n  - systemctl set-default graphical.target$') 'user-data: pacchetti e comandi del desktop'
Assert-True (@($script:ImageCatalog.Keys | Where-Object { -not $script:ImageCatalog[$_].Desktop.Packages }).Count -eq 0) 'catalogo: ogni immagine definisce i pacchetti desktop'

# --- validazione impostazioni nuova VM ---
$test = @{ Name = 'pc1'; Image = 'ubuntu26'; Ip = '192.168.0.20'; Gateway = '192.168.0.1'; MemoryMB = 2048; MaxMemoryMB = 4096; Cpus = 2; DiskGB = 30; Desktop = $false }
Set-NewVmDefaults $test
Assert-True ($test.Timezone -eq 'Europe/Rome' -and $test.KeyboardLayout -eq 'it' -and $test.Desktop -eq $false) 'impostazioni: default Europe/Rome e it'
$test.Desktop = $true
Assert-Throws { Test-NewVmSettings $test } 'password' 'desktop senza password rifiutato'
$test.PasswordHash = $hash; $test.MemoryMB = 1024
Assert-Throws { Test-NewVmSettings $test } '2048' 'desktop con poca memoria rifiutato'
$test.MemoryMB = 2048
Test-NewVmSettings $test
Assert-True $true 'desktop con password e memoria sufficiente accettato'

# --- voci Host in ~\.ssh\hvctl.conf ---
$block1 = New-SshHostBlock -Name web1 -Ip 192.168.0.20 -User mario -KeyPath 'C:\Users\x y\.ssh\hvctl\web1\id_ed25519'
Assert-True ($block1.Contains('IdentityFile "C:/Users/x y/.ssh/hvctl/web1/id_ed25519"') -and $block1 -match '(?m)^Host web1$') 'ssh config: blocco Host con percorsi quotati'
$conf = Update-SshHostBlock -Content '' -Name web1 -Block $block1
$conf = Update-SshHostBlock -Content $conf -Name web10 -Block (New-SshHostBlock -Name web10 -Ip 192.168.0.30 -User mario -KeyPath 'k')
$conf = Update-SshHostBlock -Content $conf -Name web1 -Block (New-SshHostBlock -Name web1 -Ip 192.168.0.99 -User luigi -KeyPath 'k')
Assert-True ($conf -match 'HostName 192\.168\.0\.99' -and $conf -notmatch 'HostName 192\.168\.0\.20' -and ([regex]::Matches($conf, '(?m)^Host web1$')).Count -eq 1) 'ssh config: aggiornamento sostituisce il blocco'
$conf = Update-SshHostBlock -Content $conf -Name web1 -Block $null
Assert-True ($conf -match '(?m)^Host web10$' -and $conf -notmatch '(?m)^Host web1$' -and $conf -match '192\.168\.0\.30') 'ssh config: rimozione di web1 non tocca web10'
$conf = Update-SshHostBlock -Content $conf -Name web10 -Block $null
Assert-True ($conf.Trim() -eq '') 'ssh config: vuoto dopo aver rimosso tutte le VM'

# --- vm.json: versione dello schema ---
$testHome = Join-Path ([IO.Path]::GetTempPath()) ('hvctl-test-' + [guid]::NewGuid().ToString('N'))
$previousHome = $env:HVCTL_HOME
try {
    $env:HVCTL_HOME = $testHome
    New-Item -ItemType Directory -Path (Get-VmDir 'old1') -Force | Out-Null
    '{"Name":"old1","Image":"ubuntu26","Ip":"192.168.0.50","User":"mario","Cpus":2,"MemoryMB":1024,"MaxMemoryMB":4096,"DiskGB":20}' | Set-Content -LiteralPath (Join-Path (Get-VmDir 'old1') 'vm.json')
    $old = Read-VmConfig 'old1'
    Assert-True ($old.Version -eq $script:VmConfigVersion -and $old.Desktop -eq $false -and $old.ConsolePassword -eq $false -and $old.Timezone -eq '') 'vm.json vecchio: migrato in memoria con i default'
    $old.Cpus = 4
    Save-VmConfig $old
    $saved = Get-Content -LiteralPath (Join-Path (Get-VmDir 'old1') 'vm.json') -Raw | ConvertFrom-Json
    Assert-True ($saved.Version -eq $script:VmConfigVersion -and $saved.Cpus -eq 4) 'vm.json: salvataggio con Version'
    Assert-Throws { Assert-IpAvailable @{ Ip = '192.168.0.50' } } "gia' assegnato" 'IP gia assegnato a un altra VM rifiutato'
    Assert-True ($null -eq (Assert-IpAvailable @{ Ip = '192.168.0.51' })) 'IP libero accettato'
} finally {
    $env:HVCTL_HOME = $previousHome
}

# --- ricerca IP libero (con rete simulata) ---
function Get-UsedIps { $set = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($ip in $script:fakeUsed) { [void]$set.Add($ip) }; return , $set }
function Get-RespondingIps { param([string[]]$Ips, [int]$TimeoutMs) $set = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($ip in $Ips) { if ($script:fakeUp -contains $ip) { [void]$set.Add($ip) } }; return , $set }
$script:fakeUsed = @('10.0.0.10', '10.0.0.11'); $script:fakeUp = @('10.0.0.12')
Assert-True ((Find-FreeIp -Gateway 10.0.0.1 -PrefixLength 24) -eq '10.0.0.13') 'IP libero: salta IP assegnati e IP che rispondono al ping'
$script:fakeUsed = @(); $script:fakeUp = @('10.0.0.10', '10.0.0.11', '10.0.0.12', '10.0.0.13', '10.0.0.14')
Assert-True ((Find-FreeIp -Gateway 10.0.0.1 -PrefixLength 24 -BatchSize 2) -eq '10.0.0.15') 'IP libero: funziona attraverso piu blocchi di ping'
Assert-Throws { Find-FreeIp -Gateway 10.0.0.1 -PrefixLength 30 } 'Nessun IP libero' 'IP libero: errore se la subnet e esaurita'
. (Join-Path $PSScriptRoot '..\lib\Network.ps1')
Assert-True ((Get-RespondingIps @('127.0.0.1')).Contains('127.0.0.1')) 'ping paralleli: il loopback risponde'

# --- lock e controlli preliminari ---
Assert-True ((Use-HvLock { Use-HvLock { 'rientrante' } }) -eq 'rientrante') 'lock: rientrante nello stesso thread'
Assert-Throws { Use-HvLock { throw 'errore interno' } } 'errore interno' 'lock: propaga gli errori'
Assert-True ((Use-HvLock { 'dopo errore' }) -eq 'dopo errore') 'lock: rilasciato dopo un errore'
Assert-True ((Test-HvPermission) -is [bool]) 'preflight: controllo permessi Hyper-V'
Assert-True ($null -eq (Assert-Prerequisites 'images')) 'preflight: images non richiede Hyper-V'
Assert-Throws { Assert-FreeSpace -Path $env:TEMP -RequiredBytes ([int64]::MaxValue) -Purpose 'test' } 'Spazio insufficiente' 'preflight: spazio disco insufficiente'

Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
if ($failures -gt 0) { exit 1 }
Write-Host 'Tutti i test superati.'
