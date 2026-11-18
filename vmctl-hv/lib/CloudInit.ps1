Set-StrictMode -Version 2.0

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $text = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-UserData {
    param([string]$Name, [string]$User, [string]$PublicKey)
    return @"
#cloud-config
hostname: $Name
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: '$User'
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $PublicKey
"@
}

function New-NetworkConfig {
    param([string]$Mac, [string]$Ip, [int]$PrefixLength, [string]$Gateway, [string[]]$Dns)
    $dnsList = ($Dns | ForEach-Object { "        - $_" }) -join "`n"
    return @"
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$Mac"
    set-name: eth0
    dhcp4: false
    addresses:
      - $Ip/$PrefixLength
    routes:
      - to: 0.0.0.0/0
        via: $Gateway
    nameservers:
      addresses:
$dnsList
"@
}

function New-MetaData {
    param([string]$Name)
    return "instance-id: $Name-$([guid]::NewGuid().ToString('N').Substring(0, 8))`nlocal-hostname: $Name`n"
}

# Crea un ISO9660+Joliet con etichetta 'cidata' usando IMAPI2, incluso in Windows.
function New-IsoImage {
    param([string]$SourceDir, [string]$IsoPath, [string]$Label = 'cidata')
    if (-not ('HvctlIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class HvctlIsoWriter {
    public static void Write(object comStream, string path, int blockSize, int totalBlocks) {
        IStream stream = (IStream)comStream;
        IntPtr readPtr = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write)) {
                byte[] buffer = new byte[blockSize];
                for (int i = 0; i < totalBlocks; i++) {
                    stream.Read(buffer, blockSize, readPtr);
                    file.Write(buffer, 0, Marshal.ReadInt32(readPtr));
                }
            }
        } finally {
            Marshal.FreeHGlobal(readPtr);
            Marshal.ReleaseComObject(stream);
        }
    }
}
'@
    }
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3
    $image.VolumeName = $Label
    $image.Root.AddTree($SourceDir, $false)
    $result = $image.CreateResultImage()
    [HvctlIsoWriter]::Write($result.ImageStream, $IsoPath, $result.BlockSize, $result.TotalBlocks)
}

function New-SeedIso {
    param(
        [string]$IsoPath, [string]$Name, [string]$User, [string]$PublicKey,
        [string]$Mac, [string]$Ip, [int]$PrefixLength, [string]$Gateway, [string[]]$Dns
    )
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("hvctl-seed-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Write-Utf8NoBom (Join-Path $temp 'user-data') (New-UserData -Name $Name -User $User -PublicKey $PublicKey)
        Write-Utf8NoBom (Join-Path $temp 'meta-data') (New-MetaData -Name $Name)
        Write-Utf8NoBom (Join-Path $temp 'network-config') (New-NetworkConfig -Mac (Format-Mac $Mac) -Ip $Ip -PrefixLength $PrefixLength -Gateway $Gateway -Dns $Dns)
        New-IsoImage -SourceDir $temp -IsoPath $IsoPath
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
