Set-StrictMode -Version 2.0

function ConvertTo-IpUInt32 {
    param([string]$Ip)
    $bytes = ([ipaddress]$Ip).GetAddressBytes()
    return ([int64]$bytes[0] * 16777216) + ([int64]$bytes[1] * 65536) + ([int64]$bytes[2] * 256) + [int64]$bytes[3]
}

function ConvertFrom-IpUInt32 {
    param([uint32]$Value)
    return '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255)
}

# Su uno switch NAT/interno l'host espone un vEthernet che fa da gateway della subnet delle VM.
function Get-SwitchNetwork {
    param([string]$SwitchName)
    $address = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $address) { return $null }
    return @{ Gateway = $address.IPAddress; PrefixLength = [int]$address.PrefixLength }
}

# Indirizzi gia' assegnati: VM hvctl, VM Hyper-V in esecuzione, voci ARP dell'host.
function Get-UsedIps {
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($config in Get-AllVmConfigs) { [void]$used.Add([string]$config.Ip) }
    # IP riservati dalle VM Vagrant/vmctl-go anche se spente. Cartelle extra: variabile HVCTL_LEGACY_CONFIGS (separatore ';').
    $legacyDirs = @(Join-Path $env:USERPROFILE '.vagrant-vm\configs')
    if ($env:HVCTL_LEGACY_CONFIGS) { $legacyDirs += $env:HVCTL_LEGACY_CONFIGS -split ';' | Where-Object { $_ } }
    foreach ($dir in $legacyDirs | Where-Object { Test-Path -LiteralPath $_ }) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter *.env) {
            $legacy = ConvertFrom-EnvFile $file.FullName
            if ($legacy.ContainsKey('VM_IP')) { [void]$used.Add($legacy['VM_IP']) }
        }
    }
    foreach ($vm in Get-VM -ErrorAction SilentlyContinue) {
        foreach ($adapter in $vm.NetworkAdapters) { foreach ($ip in $adapter.IPAddresses) { [void]$used.Add($ip) } }
    }
    foreach ($neighbor in Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
        if ($neighbor.State -notin 'Unreachable', 'Incomplete') { [void]$used.Add($neighbor.IPAddress) }
    }
    return , $used
}

# Ping in parallelo: restituisce l'insieme degli IP che rispondono.
function Get-RespondingIps {
    param([string[]]$Ips, [int]$TimeoutMs = 300)
    $pings = New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]
    $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    $responding = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        foreach ($ip in $Ips) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $pings.Add($ping)
            $tasks.Add($ping.SendPingAsync($ip, $TimeoutMs))
        }
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), 10000) } catch { }
        for ($i = 0; $i -lt $tasks.Count; $i++) {
            $task = $tasks[$i]
            if ($task.Status -eq 'RanToCompletion' -and $task.Result.Status -eq 'Success') { [void]$responding.Add($Ips[$i]) }
        }
    } finally {
        foreach ($ping in $pings) { $ping.Dispose() }
    }
    return , $responding
}

# Primo IP libero nella subnet del gateway, a partire da .10; i candidati vengono verificati a blocchi con ping paralleli.
function Find-FreeIp {
    param([string]$Gateway, [int]$PrefixLength = 24, [int]$FirstHost = 10, [int]$BatchSize = 32)
    $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $PrefixLength))
    $network = (ConvertTo-IpUInt32 $Gateway) -band $mask
    $broadcast = $network -bor (-bnot $mask -band [uint32]::MaxValue)
    $used = Get-UsedIps
    $batch = New-Object System.Collections.Generic.List[string]
    for ($candidate = $network + $FirstHost; $candidate -lt $broadcast; $candidate++) {
        $ip = ConvertFrom-IpUInt32 $candidate
        if ($ip -eq $Gateway -or $used.Contains($ip)) { continue }
        $batch.Add($ip)
        if ($batch.Count -ge $BatchSize) {
            $free = Get-FirstFreeIp $batch
            if ($free) { return $free }
            $batch.Clear()
        }
    }
    if ($batch.Count -gt 0) {
        $free = Get-FirstFreeIp $batch
        if ($free) { return $free }
    }
    throw "Nessun IP libero nella subnet di $Gateway/$PrefixLength."
}

function Get-FirstFreeIp {
    param([System.Collections.Generic.List[string]]$Candidates)
    $responding = Get-RespondingIps $Candidates.ToArray()
    foreach ($ip in $Candidates) { if (-not $responding.Contains($ip)) { return $ip } }
    return $null
}
