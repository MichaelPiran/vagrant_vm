Set-StrictMode -Version 2.0

function Read-MenuKey {
    if ([Console]::IsInputRedirected) { throw 'Il menu interattivo richiede una console.' }
    return [Console]::ReadKey($true)
}

function Select-Menu {
    param([string]$Title, [string[]]$Options, [int]$Default = 0)
    $index = [math]::Min($Default, $Options.Count - 1)
    $width = [Console]::WindowWidth - 1
    $lines = $Options.Count + 1
    $top = [Console]::CursorTop
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $top)
            Write-Host $Title.PadRight($width) -ForegroundColor Cyan
            for ($i = 0; $i -lt $Options.Count; $i++) {
                if ($i -eq $index) { Write-Host ("> " + $Options[$i]).PadRight($width) -ForegroundColor Cyan }
                else { Write-Host ("  " + $Options[$i]).PadRight($width) }
            }
            # Se la finestra ha scrollato, riallinea la posizione di partenza.
            $top = [Console]::CursorTop - $lines
            $key = Read-MenuKey
            switch ($key.Key) {
                'UpArrow'   { $index = ($index - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $index = ($index + 1) % $Options.Count }
                'Enter'     { $choice = $index; break }
                'Escape'    { $choice = -1; break }
            }
            if ($key.Key -in 'Enter', 'Escape') { break }
        }
        [Console]::SetCursorPosition(0, $top)
        for ($i = 0; $i -lt $lines; $i++) { Write-Host ''.PadRight($width) }
        [Console]::SetCursorPosition(0, $top)
        $answer = if ($choice -ge 0) { $Options[$choice] } else { '(annullato)' }
        Write-Host $Title -ForegroundColor Cyan -NoNewline
        Write-Host "  $answer" -ForegroundColor DarkCyan
        return $choice
    } finally {
        [Console]::CursorVisible = $true
    }
}

function Read-Value {
    param([string]$Label, [string]$Default)
    $text = if ($Default) { "$Label [$Default]" } else { $Label }
    $value = (Read-Host $text).Trim()
    if ($value -eq '') { $value = $Default }
    if ($value -eq '') { throw "$Label e' obbligatorio." }
    return $value
}

function Read-IntValue {
    param([string]$Label, [int]$Default, [int]$Minimum)
    $value = Read-Value $Label ([string]$Default)
    $number = 0
    if (-not [int]::TryParse($value, [ref]$number) -or $number -lt $Minimum) { throw "$Label deve essere un intero >= $Minimum." }
    return $number
}

function Read-IpValue {
    param([string]$Label, [string]$Default)
    $value = Read-Value $Label $Default
    if (-not (Test-Ipv4 $value)) { throw "$Label non e' un indirizzo IPv4 valido." }
    return $value
}

function Confirm-Action {
    param([string]$Message)
    return ((Select-Menu $Message @('No', 'Si')) -eq 1)
}

function Invoke-Guarded {
    param([scriptblock]$Action)
    try { & $Action } catch { Write-Host "Errore: $($_.Exception.Message)" -ForegroundColor Red }
}

function New-VmWizard {
    $ids = @($script:ImageCatalog.Keys)
    $labels = $ids | ForEach-Object {
        $state = if (Test-Path -LiteralPath (Get-BaseImagePath $_)) { 'scaricata' } else { 'da scaricare' }
        '{0,-10} {1,-14} {2}' -f $_, $script:ImageCatalog[$_].Name, $state
    }
    $selected = Select-Menu 'Immagine' @($labels)
    if ($selected -lt 0) { return $null }
    $image = $ids[$selected]
    if (-not (Test-Path -LiteralPath (Get-BaseImagePath $image))) {
        if (-not (Confirm-Action "Immagine $image non scaricata. Scaricarla ora?")) { return $null }
        Invoke-ImagePull -Id $image
    }

    $name = Read-Value 'Nome VM' "$image-vm"
    Assert-VmName $name
    if (Test-Path -LiteralPath (Get-VmDir $name)) { throw "La VM '$name' esiste gia'." }
    $user = Read-Value 'Nome utente Linux'
    Assert-GuestUser $user
    $desktop = Confirm-Action 'Installare un ambiente desktop (GUI)? Richiede una password e piu risorse'
    $passwordHash = $null
    if ($desktop -or (Confirm-Action 'Impostare una password per il login da console Hyper-V? (SSH resta con sola chiave)')) {
        $passwordHash = Read-ConsolePasswordHash
    }
    $memory = Read-IntValue 'Memoria iniziale (MB)' $(if ($desktop) { 2048 } else { 1024 }) $(if ($desktop) { 2048 } else { 512 })
    $maxMemory = Read-IntValue 'Memoria massima (MB)' ([math]::Max(4096, $memory)) $memory
    $cpus = Read-IntValue 'vCPU' 2 1
    $disk = Read-IntValue 'Disco (GB)' $(if ($desktop) { 30 } else { 20 }) 1

    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($switches.Count -gt 0) {
        $default = [math]::Max(0, [array]::IndexOf($switches, 'VMSwitchNat'))
        $pick = Select-Menu 'Switch Hyper-V' $switches $default
        if ($pick -lt 0) { return $null }
        $vmSwitch = $switches[$pick]
    } else {
        $vmSwitch = Read-Value 'Switch Hyper-V' 'VMSwitchNat'
    }

    $network = Get-SwitchNetwork $vmSwitch
    $gatewayDefault = if ($network) { $network.Gateway } else { '192.168.0.1' }
    $prefix = if ($network) { $network.PrefixLength } else { 24 }
    $gateway = Read-IpValue 'Gateway' $gatewayDefault
    Write-Host 'Ricerca di un IP libero...'
    $ip = Read-IpValue 'IP statico' (Find-FreeIp -Gateway $gateway -PrefixLength $prefix)

    $settings = @{
        Name = $name; Image = $image; Ip = $ip; Gateway = $gateway; PrefixLength = $prefix; Dns = @('1.1.1.1', '8.8.8.8')
        VmSwitch = $vmSwitch; MemoryMB = $memory; MaxMemoryMB = $maxMemory; Cpus = $cpus; DiskGB = $disk; User = $user
        Timezone = $script:DefaultTimezone; KeyboardLayout = $script:DefaultKeyboardLayout; Desktop = $desktop; PasswordHash = $passwordHash
    }
    New-HvVm -Settings $settings
    return $name
}

function Select-HvSnapshot {
    param([string]$Name)
    $snapshots = @(Get-HvSnapshots $Name)
    if ($snapshots.Count -eq 0) { Write-Host "Nessuno snapshot per $Name."; return $null }
    $labels = @($snapshots | ForEach-Object { '{0,-28} {1}' -f $_.Name, $_.CreationTime.ToString('s') })
    $pick = Select-Menu 'Snapshot' $labels ($snapshots.Count - 1)
    if ($pick -lt 0) { return $null }
    return $snapshots[$pick].Name
}

function Invoke-ResizeWizard {
    param([string]$Name)
    $config = Read-VmConfig $Name
    $changes = @{}
    $cpus = Read-IntValue 'vCPU' ([int]$config.Cpus) 1
    $memory = Read-IntValue 'Memoria iniziale (MB)' ([int]$config.MemoryMB) 512
    $maxMemory = Read-IntValue 'Memoria massima (MB)' ([math]::Max([int]$config.MaxMemoryMB, $memory)) $memory
    $disk = Read-IntValue 'Disco (GB, solo ingrandimento)' ([int]$config.DiskGB) ([int]$config.DiskGB)
    if ($cpus -ne $config.Cpus) { $changes.Cpus = $cpus }
    if ($memory -ne $config.MemoryMB) { $changes.MemoryMB = $memory }
    if ($maxMemory -ne $config.MaxMemoryMB) { $changes.MaxMemoryMB = $maxMemory }
    if ($disk -ne $config.DiskGB) { $changes.DiskGB = $disk }
    if ($changes.Count -eq 0) { Write-Host 'Nessuna modifica.'; return }
    Set-HvVmResources -Name $Name -Changes $changes
}

function Show-VmMenu {
    param([string]$Name)
    while ($true) {
        $state = (Get-VmStates)[$Name]
        if (-not $state) { $state = 'assente' }
        $choice = Select-Menu "$Name ($state)" @('Avvia', 'Connetti via SSH', 'Ferma', 'Console (log di avvio)', 'Snapshot', 'Ripristina snapshot', 'Ridimensiona', 'Destroy', 'Indietro')
        switch ($choice) {
            0 { Invoke-Guarded { Start-HvVm -Name $Name } }
            1 { Invoke-Guarded { Connect-HvVm -Name $Name } }
            2 { Invoke-Guarded { Stop-HvVm -Name $Name } }
            3 { Invoke-Guarded { Show-HvConsole -Name $Name -Start } }
            4 { Invoke-Guarded { New-HvSnapshot -Name $Name -SnapshotName (Read-Host 'Nome snapshot (vuoto = automatico)').Trim() } }
            5 {
                Invoke-Guarded {
                    $snapshot = Select-HvSnapshot $Name
                    if ($snapshot -and (Confirm-Action "Ripristinare '$snapshot'? Le modifiche successive andranno perse.")) { Restore-HvSnapshot -Name $Name -SnapshotName $snapshot }
                }
            }
            6 { Invoke-Guarded { Invoke-ResizeWizard $Name } }
            7 {
                if (Confirm-Action "Distruggere definitivamente ${Name}?") {
                    try { Remove-HvVm -Name $Name; return } catch { Write-Host "Errore: $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
            default { return }
        }
    }
}

function Start-Tui {
    while ($true) {
        $configs = @(Get-AllVmConfigs)
        $states = Get-VmStates
        $options = @($configs | ForEach-Object {
            $state = if ($states.ContainsKey($_.Name)) { $states[$_.Name] } else { 'assente' }
            '{0,-24} {1,-10} {2,-16} {3}' -f $_.Name, $state, $_.Ip, $_.Image
        })
        $options += 'Nuova VM'
        $options += 'Esci'
        $choice = Select-Menu 'VM create' $options
        if ($choice -lt 0 -or $choice -eq $options.Count - 1) { return }
        if ($choice -eq $options.Count - 2) {
            $created = $null
            try { $created = New-VmWizard } catch { Write-Host "Errore: $($_.Exception.Message)" -ForegroundColor Red }
            if ($created) { Show-VmMenu -Name ([string]($created | Select-Object -Last 1)) }
        } else {
            Show-VmMenu -Name $configs[$choice].Name
        }
    }
}
