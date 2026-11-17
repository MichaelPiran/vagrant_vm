Set-StrictMode -Version 2.0

function Find-QemuImg {
    $command = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @("$env:ProgramFiles\qemu\qemu-img.exe", "${env:ProgramFiles(x86)}\qemu\qemu-img.exe")) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "qemu-img non trovato. Installalo con: winget install SoftwareFreedomConservancy.QEMU"
}

function Get-BaseImagePath { param([string]$Id) Join-Path (Get-ImagesDir) "$Id.vhdx" }

function Invoke-ImagePull {
    param([string]$Id, [switch]$Force)
    if (-not $script:ImageCatalog.Contains($Id)) {
        throw "Immagine '$Id' sconosciuta. Disponibili: $($script:ImageCatalog.Keys -join ', ')"
    }
    $target = Get-BaseImagePath $Id
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        Write-Host "Immagine $Id gia' presente ($target). Usa -Force per riscaricarla."
        return
    }
    $qemu = Find-QemuImg
    $downloads = Join-Path (Get-ImagesDir) 'download'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    $url = $script:ImageCatalog[$Id].Url
    $source = Join-Path $downloads ([System.IO.Path]::GetFileName($url))

    Write-Host "Download $url"
    & curl.exe -fL -C - --progress-bar -o $source $url
    if ($LASTEXITCODE -ne 0) { throw "Download fallito (curl exit $LASTEXITCODE)." }

    $temporary = "$target.tmp"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Write-Host "Conversione in VHDX..."
    & $qemu convert -f qcow2 -O vhdx -o subformat=dynamic,block_size=1M $source $temporary
    if ($LASTEXITCODE -ne 0) { throw "qemu-img convert fallito (exit $LASTEXITCODE)." }
    # I VHDX creati da qemu-img risultano sparse su NTFS e Hyper-V li rifiuta.
    & fsutil.exe sparse setflag $temporary 0 | Out-Null
    Move-Item -LiteralPath $temporary -Destination $target -Force
    Write-Host "Immagine pronta: $target"
}
