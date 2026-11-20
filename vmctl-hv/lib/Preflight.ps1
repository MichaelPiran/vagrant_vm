Set-StrictMode -Version 2.0

# Controlli eseguiti all'inizio di ogni comando, per fallire subito con un messaggio chiaro
# invece che a meta' di una creazione.

function Test-HvPermission {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $hyperVAdmins = [Security.Principal.SecurityIdentifier]'S-1-5-32-578'
    return ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $principal.IsInRole($hyperVAdmins))
}

function Assert-HyperV {
    if (-not (Test-HvPermission)) {
        throw "Servono privilegi di amministratore o l'appartenenza al gruppo 'Hyper-V Administrators' (avvia il terminale come amministratore)."
    }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw "Modulo PowerShell Hyper-V non trovato: abilita la funzionalita' Hyper-V di Windows."
    }
    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') {
        throw "Il servizio Hyper-V (vmms) non e' in esecuzione: verifica che Hyper-V sia abilitato e riavvia il PC se necessario."
    }
}

function Assert-SshClient {
    [void](Find-OpenSsh 'ssh.exe')
    [void](Find-OpenSsh 'ssh-keygen.exe')
}

function Assert-FreeSpace {
    param([string]$Path, [int64]$RequiredBytes, [string]$Purpose)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        $free = (New-Object System.IO.DriveInfo $root).AvailableFreeSpace
    } catch { return }
    if ($free -lt $RequiredBytes) {
        throw ('Spazio insufficiente su {0} per {1}: liberi {2:N1} GB, necessari almeno {3:N1} GB.' -f $root, $Purpose, ($free / 1GB), ($RequiredBytes / 1GB))
    }
}

function Assert-Prerequisites {
    param([string]$Command)
    switch ($Command) {
        { $_ -in 'images', 'help' } { }
        'pull' {
            [void](Find-QemuImg)
            if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe non trovato (incluso in Windows 10/11).' }
            Assert-FreeSpace -Path (Get-HvHome) -RequiredBytes 8GB -Purpose "scaricare e convertire l'immagine"
        }
        'connect' { Assert-SshClient }
        { $_ -in 'menu', 'new', 'up' } { Assert-HyperV; Assert-SshClient }
        default { Assert-HyperV }
    }
}

# Verifiche specifiche di una nuova VM: immagine scaricata, switch esistente e spazio per la copia del disco.
function Assert-NewVmPrerequisites {
    param([hashtable]$Settings)
    if (-not $script:ImageCatalog.Contains($Settings.Image)) { throw "Immagine '$($Settings.Image)' sconosciuta. Usa: hvctl images" }
    $base = Get-BaseImagePath $Settings.Image
    if (-not (Test-Path -LiteralPath $base)) { throw "Immagine non scaricata. Esegui: hvctl pull $($Settings.Image)" }
    if (-not (Get-VMSwitch -Name $Settings.VmSwitch -ErrorAction SilentlyContinue)) { throw "Virtual switch '$($Settings.VmSwitch)' non trovato." }
    Assert-FreeSpace -Path (Get-HvHome) -RequiredBytes ((Get-Item -LiteralPath $base).Length + 1GB) -Purpose 'creare il disco della VM'
}
