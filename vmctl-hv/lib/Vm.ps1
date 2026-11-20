Set-StrictMode -Version 2.0

function Find-OpenSsh {
    param([string]$Tool)
    foreach ($dir in @("$env:WINDIR\Sysnative\OpenSSH", "$env:WINDIR\System32\OpenSSH")) {
        $path = Join-Path $dir $Tool
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $command = Get-Command $Tool -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'OpenSSH Client non installato.'
}

function Test-Ipv4 {
    param([string]$Value)
    $parsed = $null
    return ([ipaddress]::TryParse($Value, [ref]$parsed) -and $parsed.AddressFamily -eq 'InterNetwork')
}

# Le chiavi vivono in ~\.ssh\hvctl\<nome>, come vmctl-go faceva in ~\.ssh\vagrant\<nome>.
function Get-KeyDir { param([string]$Name) Join-Path (Join-Path (Join-Path $env:USERPROFILE '.ssh') 'hvctl') $Name }

function New-SshKey {
    param([string]$Name)
    $dir = Get-KeyDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'id_ed25519'
    Remove-Item -LiteralPath $path, "$path.pub" -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath (Find-OpenSsh 'ssh-keygen.exe') -ArgumentList "-q -t ed25519 -N `"`" -C `"hvctl-$Name`" -f `"$path`"" -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "ssh-keygen fallito (exit $($process.ExitCode))." }
    return $path
}

# Rimuove da known_hosts l'IP della VM, evitando avvisi di host key su IP riusati.
function Remove-KnownHost {
    param([string]$Ip)
    $knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts)) { return }
    $ErrorActionPreference = 'Continue'
    & (Find-OpenSsh 'ssh-keygen.exe') -R $Ip -f $knownHosts 2>&1 | Out-Null
    Remove-Item -LiteralPath "$knownHosts.old" -Force -ErrorAction SilentlyContinue
}

# --- Voci Host in ~\.ssh\hvctl.conf (inclusa in testa a ~\.ssh\config) per usare `ssh <nome>` e VS Code Remote-SSH ---

function Get-SshConfigPaths {
    $dir = Join-Path $env:USERPROFILE '.ssh'
    return @{ Dir = $dir; Main = (Join-Path $dir 'config'); Hvctl = (Join-Path $dir 'hvctl.conf') }
}

function Read-TextOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-SshHostBlock {
    param([string]$Name, [string]$Ip, [string]$User, [string]$KeyPath)
    $key = $KeyPath -replace '\\', '/'
    return "# hvctl:begin $Name`nHost $Name`n    HostName $Ip`n    User $User`n    IdentityFile `"$key`"`n    IdentitiesOnly yes`n    StrictHostKeyChecking accept-new`n# hvctl:end $Name`n"
}

# Sostituisce (o con $Block nullo, rimuove) il blocco gestito di una VM nel testo della configurazione.
function Update-SshHostBlock {
    param([string]$Content, [string]$Name, [string]$Block)
    $escaped = [regex]::Escape($Name)
    $clean = [regex]::Replace($Content, "(?ms)^# hvctl:begin ${escaped}\r?\n.*?^# hvctl:end ${escaped}[ \t]*(\r?\n|\z)", '')
    if ($Block) {
        if ($clean -and -not $clean.EndsWith("`n")) { $clean += "`n" }
        $clean += $Block
    }
    return $clean
}

# `Include` deve stare prima di ogni Host/Match per valere globalmente.
function Install-SshInclude {
    $paths = Get-SshConfigPaths
    $main = Read-TextOrEmpty $paths.Main
    if ($main -match '(?mi)^\s*Include\s+.*hvctl\.conf\s*$') { return }
    Write-TextNoBom $paths.Main ("Include hvctl.conf`n`n" + $main)
}

function Set-SshHostEntry {
    param([string]$Name, [string]$Ip, [string]$User)
    $key = Join-Path (Get-KeyDir $Name) 'id_ed25519'
    $paths = Get-SshConfigPaths
    try {
        Use-HvLock {
            New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
            $block = New-SshHostBlock -Name $Name -Ip $Ip -User $User -KeyPath $key
            Write-TextNoBom $paths.Hvctl (Update-SshHostBlock -Content (Read-TextOrEmpty $paths.Hvctl) -Name $Name -Block $block)
            Install-SshInclude
        }
    } catch { Write-Warning "Voce ~\.ssh\config non aggiornata: $($_.Exception.Message)" }
}

function Remove-SshHostEntry {
    param([string]$Name)
    $paths = Get-SshConfigPaths
    if (-not (Test-Path -LiteralPath $paths.Hvctl)) { return }
    try {
        Use-HvLock { Write-TextNoBom $paths.Hvctl (Update-SshHostBlock -Content (Read-TextOrEmpty $paths.Hvctl) -Name $Name -Block $null) }
    } catch { Write-Warning "Voce ~\.ssh\hvctl.conf non rimossa: $($_.Exception.Message)" }
}

# --- Prontezza della VM: login SSH reale con la chiave + fine di cloud-init ---

function Invoke-GuestSsh {
    param([string]$Ip, [string]$User, [string]$Key, [string]$Command, [int]$TimeoutSec = 30)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = Find-OpenSsh 'ssh.exe'
    $info.Arguments = "-n -i `"$Key`" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new $User@$Ip $Command"
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (($stdout.Result + $stderr.Result).Trim()); TimedOut = $false }
    } finally {
        $process.Dispose()
    }
}

# Attende che il login con la chiave funzioni (porta aperta non basta: la chiave la installa cloud-init).
function Wait-GuestSsh {
    param([string]$Ip, [string]$User, [string]$Key, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $result = Invoke-GuestSsh -Ip $Ip -User $User -Key $Key -Command 'true' -TimeoutSec 15
        if ($result.ExitCode -eq 0) { return @{ Ready = $true; Detail = '' } }
        $last = $result.Output
        Start-Sleep -Seconds 3
    }
    return @{ Ready = $false; Detail = $last }
}

# Attende la fine di cloud-init; l'esito 2 (degraded) e' un completamento con avvisi. Riprova se la connessione cade (255).
function Wait-CloudInit {
    param([string]$Ip, [string]$User, [string]$Key, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $remaining = [int][math]::Max(10, ($deadline - (Get-Date)).TotalSeconds)
        $result = Invoke-GuestSsh -Ip $Ip -User $User -Key $Key -Command 'cloud-init status --wait' -TimeoutSec $remaining
        if ($result.TimedOut) { break }
        switch ($result.ExitCode) {
            0 { return @{ Status = 'done'; Detail = $result.Output } }
            127 { return @{ Status = 'done'; Detail = '' } }
            2 { return @{ Status = 'degraded'; Detail = $result.Output } }
            255 { Start-Sleep -Seconds 3 }
            default { return @{ Status = 'error'; Detail = $result.Output } }
        }
    }
    return @{ Status = 'timeout'; Detail = '' }
}

function Get-VmStates {
    $states = @{}
    Get-VM -ErrorAction SilentlyContinue | ForEach-Object { $states[$_.Name] = ([string]$_.State).ToLower() }
    return $states
}

function Remove-VmQuietly {
    param([string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
        Remove-VM -Name $Name -Force
    }
}

function Get-MinMemoryMB { param([int]$MemoryMB) return [math]::Min($MemoryMB, 512) }

function Set-NewVmDefaults {
    param([hashtable]$Settings)
    $defaults = @{ Timezone = $script:DefaultTimezone; KeyboardLayout = $script:DefaultKeyboardLayout; Desktop = $false; PasswordHash = $null }
    foreach ($key in $defaults.Keys) {
        if (-not $Settings.ContainsKey($key) -or ($null -eq $Settings[$key] -and $key -ne 'PasswordHash')) { $Settings[$key] = $defaults[$key] }
    }
}

function Test-NewVmSettings {
    param([hashtable]$Settings)
    Assert-VmName $Settings.Name
    if (-not $script:ImageCatalog.Contains($Settings.Image)) { throw "Immagine '$($Settings.Image)' sconosciuta. Usa: hvctl images" }
    if (-not (Test-Ipv4 $Settings.Ip) -or -not (Test-Ipv4 $Settings.Gateway)) { throw 'Specificare -Ip e -Gateway IPv4 validi.' }
    Assert-Timezone $Settings.Timezone
    Assert-KeyboardLayout $Settings.KeyboardLayout
    if ($Settings.MemoryMB -lt 512 -or $Settings.MaxMemoryMB -lt $Settings.MemoryMB -or $Settings.Cpus -lt 1 -or $Settings.DiskGB -lt 1) {
        throw 'Valori di RAM/CPU/disco non validi (RAM minima 512 MB).'
    }
    if ($Settings.Desktop) {
        if ($Settings.MemoryMB -lt 2048) { throw 'Con -Desktop servono almeno 2048 MB di memoria iniziale.' }
        if (-not $Settings.PasswordHash) { throw 'Con -Desktop serve una password per il login grafico (-Password).' }
    }
}

# Da chiamare dentro il lock: l'IP puo' essere stato assegnato da un'altra istanza dopo la scelta.
function Assert-IpAvailable {
    param([hashtable]$Settings)
    $owner = Get-AllVmConfigs | Where-Object { $_.Ip -eq $Settings.Ip } | Select-Object -First 1
    if ($owner) { throw "L'IP $($Settings.Ip) e' gia' assegnato alla VM '$($owner.Name)'." }
}

# Le chiamate dall'esterno che gia' tengono il lock (es. `new` con scelta dell'IP) usano -NoStart e avviano la VM dopo.
function New-HvVm {
    param([hashtable]$Settings, [switch]$NoStart, [int]$SshTimeoutSec = 180, [int]$CloudInitTimeoutSec = 0)
    Set-NewVmDefaults $Settings
    Test-NewVmSettings $Settings
    Assert-NewVmPrerequisites $Settings
    $name = $Settings.Name
    $base = Get-BaseImagePath $Settings.Image
    $vmDir = Get-VmDir $name
    $desktop = if ($Settings.Desktop) { $script:ImageCatalog[$Settings.Image].Desktop } else { $null }
    $packages = @(if ($desktop) { $desktop.Packages })
    $runCmd = @(if ($desktop) { $desktop.RunCmd })

    Use-HvLock {
        Assert-IpAvailable $Settings
        if ((Test-Path -LiteralPath $vmDir) -or (Get-VM -Name $name -ErrorAction SilentlyContinue)) { throw "La VM '$name' esiste gia'." }

        New-Item -ItemType Directory -Path $vmDir | Out-Null
        try {
            $keyPath = New-SshKey $name
            Remove-KnownHost $Settings.Ip
            $mac = New-MacAddress $name
            $seed = Join-Path $vmDir 'seed.iso'
            New-SeedIso -IsoPath $seed -Name $name -User $Settings.User -PublicKey (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim() `
                -Mac $mac -Ip $Settings.Ip -PrefixLength $Settings.PrefixLength -Gateway $Settings.Gateway -Dns $Settings.Dns `
                -Timezone $Settings.Timezone -KeyboardLayout $Settings.KeyboardLayout -PasswordHash $Settings.PasswordHash -Packages $packages -RunCmd $runCmd

            $disk = Join-Path $vmDir "$name.vhdx"
            Copy-Item -LiteralPath $base -Destination $disk
            $diskBytes = [uint64]$Settings.DiskGB * 1GB
            if ((Get-VHD -Path $disk).Size -lt $diskBytes) { Resize-VHD -Path $disk -SizeBytes $diskBytes }

            New-VM -Name $name -Generation 2 -MemoryStartupBytes ([int64]$Settings.MemoryMB * 1MB) -VHDPath $disk -SwitchName $Settings.VmSwitch -Path (Join-Path $vmDir 'hv') | Out-Null
            Set-VM -Name $name -ProcessorCount $Settings.Cpus -DynamicMemory -MemoryMinimumBytes ([int64](Get-MinMemoryMB $Settings.MemoryMB) * 1MB) -MemoryMaximumBytes ([int64]$Settings.MaxMemoryMB * 1MB)
            # Senza questo Hyper-V crea un checkpoint a ogni avvio, confondendosi con gli snapshot gestiti da hvctl.
            if ((Get-Command Set-VM).Parameters.ContainsKey('AutomaticCheckpointsEnabled')) { Set-VM -Name $name -AutomaticCheckpointsEnabled $false }
            Set-VMFirmware -VMName $name -EnableSecureBoot Off
            Set-VMNetworkAdapter -VMName $name -StaticMacAddress $mac
            Add-VMDvdDrive -VMName $name -Path $seed
            Set-VMComPort -VMName $name -Number 1 -Path (Get-ConsolePipePath $name)

            Save-VmConfig ([pscustomobject]@{
                Name = $name; Image = $Settings.Image; Ip = $Settings.Ip; Gateway = $Settings.Gateway; PrefixLength = $Settings.PrefixLength
                Switch = $Settings.VmSwitch; MemoryMB = $Settings.MemoryMB; MaxMemoryMB = $Settings.MaxMemoryMB; Cpus = $Settings.Cpus
                DiskGB = $Settings.DiskGB; User = $Settings.User; Mac = $mac; Created = (Get-Date).ToString('s')
                Timezone = $Settings.Timezone; KeyboardLayout = $Settings.KeyboardLayout
                ConsolePassword = [bool]$Settings.PasswordHash; Desktop = [bool]$Settings.Desktop; Version = $script:VmConfigVersion
            })
            Set-SshHostEntry -Name $name -Ip $Settings.Ip -User $Settings.User
        } catch {
            Remove-VmQuietly $name
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-KeyDir $name) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-SshHostEntry $name
            throw
        }
    }
    Write-Host "VM $name creata."
    if (-not $NoStart) { Start-HvVm -Name $name -SshTimeoutSec $SshTimeoutSec -CloudInitTimeoutSec $CloudInitTimeoutSec }
}

function Start-HvVm {
    param([string]$Name, [int]$SshTimeoutSec = 180, [int]$CloudInitTimeoutSec = 0)
    $config = Read-VmConfig $Name
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$Name' assente in Hyper-V (rimossa a mano?). Esegui destroy e new." }
    if ($CloudInitTimeoutSec -le 0) { $CloudInitTimeoutSec = if ($config.Desktop) { 2400 } else { 600 } }
    switch ([string]$vm.State) {
        'Running' { }
        'Paused' { Resume-VM -Name $Name }
        default { Start-VM -Name $Name }
    }
    $key = Join-Path (Get-KeyDir $Name) 'id_ed25519'
    if (Test-Path -LiteralPath $key) { Set-SshHostEntry -Name $Name -Ip $config.Ip -User $config.User }

    Write-Host "Attesa login SSH su $($config.User)@$($config.Ip)..."
    $ssh = Wait-GuestSsh -Ip $config.Ip -User $config.User -Key $key -TimeoutSec $SshTimeoutSec
    if (-not $ssh.Ready) {
        $detail = if ($ssh.Detail) { " Ultimo errore: $($ssh.Detail)" } else { '' }
        Write-Warning "Login SSH non riuscito entro $SshTimeoutSec s (il primo boot con cloud-init puo' richiedere di piu'). Diagnostica: hvctl console $Name.$detail"
        return
    }
    Write-Host 'SSH raggiungibile, attesa fine di cloud-init...'
    $cloudInit = Wait-CloudInit -Ip $config.Ip -User $config.User -Key $key -TimeoutSec $CloudInitTimeoutSec
    switch ($cloudInit.Status) {
        'done' { Write-Host 'Pronta.' }
        'degraded' { Write-Warning "cloud-init terminato con avvisi: la VM e' utilizzabile, ma controlla 'cloud-init status --long' via SSH. $($cloudInit.Detail)" }
        'error' { Write-Warning "cloud-init ha riportato un errore (diagnostica: hvctl console $Name). $($cloudInit.Detail)" }
        default { Write-Warning "cloud-init non e' terminato entro $CloudInitTimeoutSec s: la VM risponde ma la configurazione puo' essere incompleta." }
    }
}

function Stop-HvVm {
    param([string]$Name, [switch]$Force)
    Read-VmConfig $Name | Out-Null
    if ($Force) { Stop-VM -Name $Name -TurnOff -Force } else { Stop-VM -Name $Name }
}

function Get-ConsolePipePath { param([string]$Name) "\\.\pipe\hvctl-$Name" }

# Mostra e salva su vms\<nome>\console.log l'output della porta seriale (log di boot del kernel e di cloud-init).
function Show-HvConsole {
    param([string]$Name, [int]$Seconds = 0, [switch]$Start)
    Read-VmConfig $Name | Out-Null
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$Name' assente in Hyper-V." }

    $path = Get-ConsolePipePath $Name
    if ((Get-VMComPort -VMName $Name -Number 1).Path -ne $path) {
        if ($vm.State -ne 'Off') { throw "La VM '$Name' non ha la porta seriale configurata: spegnila (stop -Force) e rilancia il comando." }
        Set-VMComPort -VMName $Name -Number 1 -Path $path
    }
    if ($vm.State -ne 'Running') {
        if (-not $Start) { throw "VM '$Name' non in esecuzione: usa -Start per avviarla e catturare il boot." }
        Start-VM -Name $Name
    }

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', "hvctl-$Name", [System.IO.Pipes.PipeDirection]::In)
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $pipe.IsConnected) {
        try { $pipe.Connect(1000) } catch [System.TimeoutException] {
            if ((Get-Date) -gt $deadline) { $pipe.Dispose(); throw 'Porta seriale non raggiungibile (e'' gia'' in uso da un altro programma?).' }
        }
    }

    $logPath = Join-Path (Get-VmDir $Name) 'console.log'
    $log = New-Object System.IO.StreamWriter($logPath, $true, (New-Object System.Text.UTF8Encoding($false)))
    $log.AutoFlush = $true
    $log.WriteLine("===== console $(Get-Date -Format s) =====")
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $buffer = New-Object byte[] 4096
    $chars = New-Object char[] 4096
    $stopAt = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
    $interactive = -not [Console]::IsInputRedirected
    Write-Host "Console di $Name (q o Esc per terminare). Log: $logPath" -ForegroundColor Cyan
    $read = $null
    $pending = ''
    try {
        while ((Get-Date) -lt $stopAt) {
            if ($interactive -and [Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -in 'Q', 'Escape') { break }
            }
            if (-not $read) { $read = $pipe.ReadAsync($buffer, 0, $buffer.Length) }
            if (-not $read.Wait(500)) { continue }
            $count = $read.Result
            $read = $null
            if ($count -le 0) { Write-Host '[console chiusa: VM spenta]' -ForegroundColor Yellow; break }
            $text = $pending + [string]::new($chars, 0, $decoder.GetChars($buffer, 0, $count, $chars, 0))
            # Una sequenza di escape spezzata tra due letture viene completata alla lettura successiva.
            $tail = [regex]::Match($text, '\x1b(\[[0-9;?]*|[()]|\][^\x07]*)?$')
            $pending = $tail.Value
            if ($tail.Success) { $text = $text.Substring(0, $tail.Index) }
            $text = ($text -replace '\x1b(\[[0-9;?]*[A-Za-z]|[()][A-Z0-9]|\][^\x07]*\x07)', '') -replace '[\r\x1b]', ''
            [Console]::Out.Write($text)
            $log.Write($text)
        }
    } finally {
        $log.Dispose()
        $pipe.Dispose()
    }
    Write-Host "`nLog salvato in $logPath" -ForegroundColor Cyan
}

function Connect-HvVm {
    param([string]$Name)
    $config = Read-VmConfig $Name
    $key = Join-Path (Get-KeyDir $Name) 'id_ed25519'
    if (-not (Test-Path -LiteralPath $key)) { throw "Chiave SSH non trovata: $key" }
    & (Find-OpenSsh 'ssh.exe') -i $key -o StrictHostKeyChecking=accept-new "$($config.User)@$($config.Ip)"
}

function Remove-HvVm {
    param([string]$Name)
    $config = Read-VmConfig $Name
    Remove-VmQuietly $Name
    Remove-Item -LiteralPath (Get-VmDir $Name) -Recurse -Force
    Remove-Item -LiteralPath (Get-KeyDir $Name) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-KnownHost $config.Ip
    Remove-SshHostEntry $Name
    Write-Host "VM $Name eliminata."
}

function Get-HvVmOrThrow {
    param([string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$Name' assente in Hyper-V (rimossa a mano?). Esegui destroy e new." }
    return $vm
}

# Riallinea vm.json alla configurazione reale in Hyper-V (dopo resize o restore di uno snapshot).
function Sync-VmConfig {
    param([string]$Name)
    $config = Read-VmConfig $Name
    $vm = Get-HvVmOrThrow $Name
    $memory = Get-VMMemory -VMName $Name
    $config.Cpus = [int](Get-VMProcessor -VMName $Name).Count
    $config.MemoryMB = [int]($memory.Startup / 1MB)
    $config.MaxMemoryMB = [int]($memory.Maximum / 1MB)
    $drive = $vm.HardDrives | Select-Object -First 1
    if ($drive) { $config.DiskGB = [int][math]::Round((Get-VHD -Path $drive.Path).Size / 1GB) }
    Save-VmConfig $config
}

# $Changes puo' contenere Cpus, MemoryMB, MaxMemoryMB, DiskGB; la VM deve essere spenta e il disco puo' solo crescere.
function Set-HvVmResources {
    param([string]$Name, [hashtable]$Changes)
    if ($Changes.Count -eq 0) { throw 'Specificare almeno uno tra -Cpus, -MemoryMB, -MaxMemoryMB, -DiskGB.' }
    $config = Read-VmConfig $Name
    $vm = Get-HvVmOrThrow $Name
    if ($vm.State -ne 'Off') { throw "La VM '$Name' deve essere spenta: esegui 'hvctl stop $Name'." }

    $cpus = if ($Changes.ContainsKey('Cpus')) { [int]$Changes.Cpus } else { [int]$config.Cpus }
    $memory = if ($Changes.ContainsKey('MemoryMB')) { [int]$Changes.MemoryMB } else { [int]$config.MemoryMB }
    $maxMemory = if ($Changes.ContainsKey('MaxMemoryMB')) { [int]$Changes.MaxMemoryMB } else { [int]$config.MaxMemoryMB }
    if ($Changes.ContainsKey('MemoryMB') -and -not $Changes.ContainsKey('MaxMemoryMB')) { $maxMemory = [math]::Max($maxMemory, $memory) }
    if ($cpus -lt 1 -or $memory -lt 512 -or $maxMemory -lt $memory) { throw 'Valori di RAM/CPU non validi (RAM minima 512 MB, massima >= iniziale).' }
    if ($config.Desktop -and $memory -lt 2048) { throw 'Questa VM ha il desktop: servono almeno 2048 MB di memoria iniziale.' }

    $drive = $vm.HardDrives | Select-Object -First 1
    $diskBytes = $null
    if ($Changes.ContainsKey('DiskGB')) {
        $diskBytes = [int64]$Changes.DiskGB * 1GB
        $currentBytes = (Get-VHD -Path $drive.Path).Size
        if ($diskBytes -lt $currentBytes) { throw "Il disco puo' solo essere ingrandito (attuale: $([math]::Round($currentBytes / 1GB)) GB)." }
        if ($diskBytes -gt $currentBytes -and @(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Impossibile ingrandire il disco con snapshot presenti: elimina gli snapshot da Hyper-V Manager e riprova."
        }
    }

    Set-VMProcessor -VMName $Name -Count $cpus
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -StartupBytes ([int64]$memory * 1MB) -MinimumBytes ([int64](Get-MinMemoryMB $memory) * 1MB) -MaximumBytes ([int64]$maxMemory * 1MB)
    if ($diskBytes -and $diskBytes -gt (Get-VHD -Path $drive.Path).Size) { Resize-VHD -Path $drive.Path -SizeBytes $diskBytes }
    Sync-VmConfig $Name
    Write-Host "VM $Name ridimensionata. Al prossimo avvio cloud-init espande partizione e filesystem se il disco e' cresciuto."
}

function New-HvSnapshot {
    param([string]$Name, [string]$SnapshotName)
    Read-VmConfig $Name | Out-Null
    Get-HvVmOrThrow $Name | Out-Null
    if (-not $SnapshotName) { $SnapshotName = 'snap-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    if (Get-VMSnapshot -VMName $Name -Name $SnapshotName -ErrorAction SilentlyContinue) { throw "Esiste gia' uno snapshot '$SnapshotName' per '$Name'." }
    Checkpoint-VM -Name $Name -SnapshotName $SnapshotName
    Write-Host "Snapshot '$SnapshotName' creato per $Name."
}

function Get-HvSnapshots {
    param([string]$Name)
    Read-VmConfig $Name | Out-Null
    Get-HvVmOrThrow $Name | Out-Null
    return @(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue | Sort-Object CreationTime)
}

function Show-HvSnapshots {
    param([string]$Name)
    $snapshots = @(Get-HvSnapshots $Name)
    if ($snapshots.Count -eq 0) { Write-Host "Nessuno snapshot per $Name."; return }
    $snapshots | ForEach-Object { [pscustomobject]@{ Nome = $_.Name; Creato = $_.CreationTime.ToString('s'); Padre = $_.ParentSnapshotName } } | Format-Table -AutoSize
}

# Senza nome ripristina l'ultimo snapshot.
function Restore-HvSnapshot {
    param([string]$Name, [string]$SnapshotName)
    $snapshots = @(Get-HvSnapshots $Name)
    if ($snapshots.Count -eq 0) { throw "Nessuno snapshot per '$Name'." }
    $snapshot = if ($SnapshotName) { $snapshots | Where-Object { $_.Name -eq $SnapshotName } | Select-Object -First 1 } else { $snapshots | Select-Object -Last 1 }
    if (-not $snapshot) { throw "Snapshot '$SnapshotName' non trovato. Disponibili: $(($snapshots | ForEach-Object { $_.Name }) -join ', ')" }
    Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
    Sync-VmConfig $Name
    Write-Host "Snapshot '$($snapshot.Name)' ripristinato per $Name (stato: $((Get-VM -Name $Name).State)). Usa 'hvctl up $Name' per avviarla."
}
