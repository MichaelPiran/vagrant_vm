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

function Wait-Ssh {
    param([string]$Ip, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $attempt = $client.ConnectAsync($Ip, 22)
            if ($attempt.Wait(2000) -and $client.Connected) { return $true }
        } catch { } finally { $client.Dispose() }
        Start-Sleep -Seconds 2
    }
    return $false
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

function Test-NewVmSettings {
    param([hashtable]$Settings)
    Assert-VmName $Settings.Name
    if (-not $script:ImageCatalog.Contains($Settings.Image)) { throw "Immagine '$($Settings.Image)' sconosciuta. Usa: hvctl images" }
    if (-not (Test-Ipv4 $Settings.Ip) -or -not (Test-Ipv4 $Settings.Gateway)) { throw 'Specificare -Ip e -Gateway IPv4 validi.' }
    $owner = Get-AllVmConfigs | Where-Object { $_.Ip -eq $Settings.Ip } | Select-Object -First 1
    if ($owner) { throw "L'IP $($Settings.Ip) e' gia' assegnato alla VM '$($owner.Name)'." }
    if ($Settings.MemoryMB -lt 512 -or $Settings.MaxMemoryMB -lt $Settings.MemoryMB -or $Settings.Cpus -lt 1 -or $Settings.DiskGB -lt 1) {
        throw 'Valori di RAM/CPU/disco non validi (RAM minima 512 MB).'
    }
}

function New-HvVm {
    param([hashtable]$Settings, [switch]$NoStart, [int]$SshTimeoutSec = 180)
    Test-NewVmSettings $Settings
    $name = $Settings.Name
    $base = Get-BaseImagePath $Settings.Image
    if (-not (Test-Path -LiteralPath $base)) { throw "Immagine non scaricata. Esegui: hvctl pull $($Settings.Image)" }
    $vmDir = Get-VmDir $name
    if ((Test-Path -LiteralPath $vmDir) -or (Get-VM -Name $name -ErrorAction SilentlyContinue)) { throw "La VM '$name' esiste gia'." }
    if (-not (Get-VMSwitch -Name $Settings.VmSwitch -ErrorAction SilentlyContinue)) { throw "Virtual switch '$($Settings.VmSwitch)' non trovato." }

    New-Item -ItemType Directory -Path $vmDir | Out-Null
    try {
        $keyPath = New-SshKey $name
        Remove-KnownHost $Settings.Ip
        $mac = New-MacAddress $name
        $seed = Join-Path $vmDir 'seed.iso'
        New-SeedIso -IsoPath $seed -Name $name -User $Settings.User -PublicKey (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim() `
            -Mac $mac -Ip $Settings.Ip -PrefixLength $Settings.PrefixLength -Gateway $Settings.Gateway -Dns $Settings.Dns

        $disk = Join-Path $vmDir "$name.vhdx"
        Copy-Item -LiteralPath $base -Destination $disk
        $diskBytes = [uint64]$Settings.DiskGB * 1GB
        if ((Get-VHD -Path $disk).Size -lt $diskBytes) { Resize-VHD -Path $disk -SizeBytes $diskBytes }

        New-VM -Name $name -Generation 2 -MemoryStartupBytes ([int64]$Settings.MemoryMB * 1MB) -VHDPath $disk -SwitchName $Settings.VmSwitch -Path (Join-Path $vmDir 'hv') | Out-Null
        Set-VM -Name $name -ProcessorCount $Settings.Cpus -DynamicMemory -MemoryMinimumBytes ([int64][math]::Min($Settings.MemoryMB, 512) * 1MB) -MemoryMaximumBytes ([int64]$Settings.MaxMemoryMB * 1MB)
        Set-VMFirmware -VMName $name -EnableSecureBoot Off
        Set-VMNetworkAdapter -VMName $name -StaticMacAddress $mac
        Add-VMDvdDrive -VMName $name -Path $seed
        Set-VMComPort -VMName $name -Number 1 -Path (Get-ConsolePipePath $name)

        [pscustomobject]@{
            Name = $name; Image = $Settings.Image; Ip = $Settings.Ip; Gateway = $Settings.Gateway; PrefixLength = $Settings.PrefixLength
            Switch = $Settings.VmSwitch; MemoryMB = $Settings.MemoryMB; MaxMemoryMB = $Settings.MaxMemoryMB; Cpus = $Settings.Cpus
            DiskGB = $Settings.DiskGB; User = $Settings.User; Mac = $mac; Created = (Get-Date).ToString('s')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $vmDir 'vm.json') -Encoding UTF8
    } catch {
        Remove-VmQuietly $name
        Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-KeyDir $name) -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "VM $name creata."
    if (-not $NoStart) { Start-HvVm -Name $name -SshTimeoutSec $SshTimeoutSec }
}

function Start-HvVm {
    param([string]$Name, [int]$SshTimeoutSec = 180)
    $config = Read-VmConfig $Name
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$Name' assente in Hyper-V (rimossa a mano?). Esegui destroy e new." }
    if ($vm.State -ne 'Running') { Start-VM -Name $Name }
    Write-Host "Attesa SSH su $($config.Ip)..."
    if (Wait-Ssh -Ip $config.Ip -TimeoutSec $SshTimeoutSec) {
        Write-Host 'Pronta.'
    } else {
        Write-Warning "SSH non raggiungibile entro $SshTimeoutSec s (il primo boot con cloud-init puo' richiedere di piu')."
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
    Write-Host "VM $Name eliminata."
}
