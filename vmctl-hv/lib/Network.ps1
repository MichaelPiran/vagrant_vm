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
    # IP riservati dalle VM Vagrant/vmctl-go anche se spente.
    $legacyDirs = @((Join-Path $PSScriptRoot '..\..\configs'), (Join-Path $env:USERPROFILE '.vagrant-vm\configs'))
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
    return $used
}

function Test-IpResponds {
    param([string]$Ip)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { return ($ping.Send($Ip, 300).Status -eq 'Success') } catch { return $false } finally { $ping.Dispose() }
}

# Primo IP libero nella subnet del gateway, a partire da .10.
function Find-FreeIp {
    param([string]$Gateway, [int]$PrefixLength = 24, [int]$FirstHost = 10)
    $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $PrefixLength))
    $network = (ConvertTo-IpUInt32 $Gateway) -band $mask
    $broadcast = $network -bor (-bnot $mask -band [uint32]::MaxValue)
    $used = Get-UsedIps
    for ($candidate = $network + $FirstHost; $candidate -lt $broadcast; $candidate++) {
        $ip = ConvertFrom-IpUInt32 $candidate
        if ($ip -eq $Gateway -or $used.Contains($ip)) { continue }
        if (-not (Test-IpResponds $ip)) { return $ip }
    }
    throw "Nessun IP libero nella subnet di $Gateway/$PrefixLength."
}
