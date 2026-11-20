Set-StrictMode -Version 2.0

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $text = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-UserData {
    param(
        [string]$Name, [string]$User, [string]$PublicKey,
        [string]$Timezone = 'Europe/Rome', [string]$KeyboardLayout = 'it',
        [string]$PasswordHash, [string[]]$Packages = @(), [string[]]$RunCmd = @()
    )
    $Packages = @($Packages | Where-Object { $_ })
    $RunCmd = @($RunCmd | Where-Object { $_ })
    # Con password impostata l'account e' sbloccato solo per il login da console; SSH resta con sola chiave (ssh_pwauth: false).
    $lockPasswd = if ($PasswordHash) { 'false' } else { 'true' }
    $passwdLine = if ($PasswordHash) { "`n    passwd: '$PasswordHash'" } else { '' }
    $extra = ''
    if ($Packages.Count -gt 0) {
        $extra += "package_update: true`npackages:`n" + (($Packages | ForEach-Object { "  - $_" }) -join "`n") + "`n"
    }
    if ($RunCmd.Count -gt 0) {
        $extra += "runcmd:`n" + (($RunCmd | ForEach-Object { "  - $_" }) -join "`n") + "`n"
    }
    return @"
#cloud-config
hostname: $Name
manage_etc_hosts: true
timezone: $Timezone
keyboard:
  layout: $KeyboardLayout
ssh_pwauth: false
users:
  - name: '$User'
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: $lockPasswd$passwdLine
    ssh_authorized_keys:
      - $PublicKey
$extra
"@
}

# Hash SHA-512 crypt ($6$) compatibile con /etc/shadow, calcolato qui perche' Windows non ha crypt(3).
function ConvertTo-PasswordHash {
    param([string]$Password, [string]$Salt)
    if (-not ('HvctlCrypt' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

public static class HvctlCrypt {
    public const string Alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    static byte[] Sha(params byte[][] parts) {
        using (SHA512 sha = SHA512.Create()) {
            foreach (byte[] part in parts) sha.TransformBlock(part, 0, part.Length, null, 0);
            sha.TransformFinalBlock(new byte[0], 0, 0);
            return sha.Hash;
        }
    }

    static byte[] Slice(byte[] source, int length) {
        byte[] result = new byte[length];
        Array.Copy(source, result, length);
        return result;
    }

    static byte[] Repeat(byte[] source, int times) {
        byte[] result = new byte[source.Length * times];
        for (int i = 0; i < times; i++) Array.Copy(source, 0, result, i * source.Length, source.Length);
        return result;
    }

    static byte[] Fill(byte[] source, int length) {
        byte[] result = new byte[length];
        for (int i = 0; i < length; i++) result[i] = source[i % source.Length];
        return result;
    }

    static void Encode(StringBuilder output, byte b2, byte b1, byte b0, int count) {
        int word = (b2 << 16) | (b1 << 8) | b0;
        for (int i = 0; i < count; i++) { output.Append(Alphabet[word & 0x3f]); word >>= 6; }
    }

    public static string Hash(string password, string salt) {
        if (salt.Length > 16) salt = salt.Substring(0, 16);
        byte[] key = Encoding.UTF8.GetBytes(password);
        byte[] saltBytes = Encoding.UTF8.GetBytes(salt);
        byte[] empty = new byte[0];

        byte[] alt = Sha(key, saltBytes, key);
        List<byte[]> parts = new List<byte[]>();
        parts.Add(key);
        parts.Add(saltBytes);
        int count;
        for (count = key.Length; count > 64; count -= 64) parts.Add(alt);
        parts.Add(Slice(alt, count));
        for (count = key.Length; count > 0; count >>= 1) parts.Add((count & 1) != 0 ? alt : key);
        byte[] digest = Sha(parts.ToArray());

        byte[] p = Fill(Sha(Repeat(key, key.Length)), key.Length);
        byte[] s = Fill(Sha(Repeat(saltBytes, 16 + digest[0])), saltBytes.Length);

        for (int i = 0; i < 5000; i++) {
            byte[] odd = (i & 1) != 0 ? p : digest;
            byte[] even = (i & 1) != 0 ? digest : p;
            digest = Sha(odd, (i % 3) != 0 ? s : empty, (i % 7) != 0 ? p : empty, even);
        }

        int[,] order = {
            {0,21,42},{22,43,1},{44,2,23},{3,24,45},{25,46,4},{47,5,26},{6,27,48},{28,49,7},{50,8,29},{9,30,51},{31,52,10},
            {53,11,32},{12,33,54},{34,55,13},{56,14,35},{15,36,57},{37,58,16},{59,17,38},{18,39,60},{40,61,19},{62,20,41}
        };
        StringBuilder result = new StringBuilder("$6$").Append(salt).Append('$');
        for (int i = 0; i < order.GetLength(0); i++) Encode(result, digest[order[i, 0]], digest[order[i, 1]], digest[order[i, 2]], 4);
        Encode(result, 0, 0, digest[63], 2);
        return result.ToString();
    }
}
'@
    }
    if (-not $Salt) {
        $random = New-Object byte[] 16
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($random) } finally { $rng.Dispose() }
        $Salt = -join ($random | ForEach-Object { [HvctlCrypt]::Alphabet[$_ -band 63] })
    }
    return [HvctlCrypt]::Hash($Password, $Salt)
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
        [string]$Mac, [string]$Ip, [int]$PrefixLength, [string]$Gateway, [string[]]$Dns,
        [string]$Timezone = 'Europe/Rome', [string]$KeyboardLayout = 'it',
        [string]$PasswordHash, [string[]]$Packages = @(), [string[]]$RunCmd = @()
    )
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("hvctl-seed-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $userData = New-UserData -Name $Name -User $User -PublicKey $PublicKey -Timezone $Timezone -KeyboardLayout $KeyboardLayout `
            -PasswordHash $PasswordHash -Packages $Packages -RunCmd $RunCmd
        Write-Utf8NoBom (Join-Path $temp 'user-data') $userData
        Write-Utf8NoBom (Join-Path $temp 'meta-data') (New-MetaData -Name $Name)
        Write-Utf8NoBom (Join-Path $temp 'network-config') (New-NetworkConfig -Mac (Format-Mac $Mac) -Ip $Ip -PrefixLength $PrefixLength -Gateway $Gateway -Dns $Dns)
        New-IsoImage -SourceDir $temp -IsoPath $IsoPath
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
