# Tempra (ex Nomorediet) su iPhone da un PC Windows: scarica e installa quello che serve.
#   irm https://raw.githubusercontent.com/Redwraith/nomorediet-ios/main/scripts/windows/installa.ps1 | iex
# 1. iTunes (driver Apple per vedere l'iPhone via USB)
# 2. Impactor (installa le app con il tuo Apple ID, mantenendo il permesso di Apple Salute)
# 3. Nomorediet.ipa (ultima versione)
# 4. facoltativo: Python + pymobiledevice3 e Claude Code, per far controllare l'iPhone a Claude da questo PC
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$dir = Join-Path $env:USERPROFILE "Downloads\Nomorediet"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Passo($n, $testo) { Write-Host "`n[$n] $testo" -ForegroundColor Green }

Passo "1/4" "iTunes (driver per l'iPhone)"
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id Apple.iTunes -e --accept-source-agreements --accept-package-agreements
} else {
    Write-Host "winget non c'e': installa iTunes da https://www.apple.com/itunes/ (versione per Windows) e rilancia." -ForegroundColor Yellow
}

Passo "2/4" "Impactor"
# Le release hanno piu' eseguibili Windows (x86_64, x86, arm64, setup, portable, plumesign a riga di comando):
# si prende l'installer per l'architettura di questo PC.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } elseif ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
$rel = $null
foreach ($repo in @("claration/impactor", "khcrysalis/PlumeImpactor")) {
    try { $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ "User-Agent" = "tempra" }; break } catch { }
}
if (-not $rel) { throw "Non riesco a leggere le release di Impactor: scaricalo a mano da https://github.com/claration/impactor/releases/latest" }
$asset = $rel.assets | Where-Object { $_.name -eq "Impactor-windows-$arch-setup.exe" } | Select-Object -First 1
if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -eq "Impactor-windows-$arch-portable.exe" } | Select-Object -First 1 }
if (-not $asset) { throw "Non trovo Impactor per Windows $arch: scaricalo a mano da $($rel.html_url) (file Impactor-windows-$arch-setup.exe)" }
$impactor = Join-Path $dir $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $impactor
Unblock-File $impactor
Write-Host "Scaricato: $impactor ($($rel.tag_name), $arch)"

Passo "3/4" "Nomorediet.ipa"
$ipa = Join-Path $dir "Nomorediet.ipa"
Invoke-WebRequest -Uri "https://github.com/Redwraith/nomorediet-ios/releases/download/piatto-ios/Nomorediet.ipa" -OutFile $ipa
Write-Host "Scaricato: $ipa"

Passo "4/4" "Facoltativo: strumenti per far controllare l'iPhone a Claude da questo PC"
$si = Read-Host "Installare Python, pymobiledevice3 e Claude Code? (s/n)"
if ($si -match '^[sSyY]') {
    winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    py -3.12 -m pip install --upgrade pymobiledevice3
    irm https://claude.ai/install.ps1 | iex
}

Write-Host "`nFatto. Ora:" -ForegroundColor Green
Write-Host " - apri Impactor (si apre adesso), collega l'iPhone via USB e tocca 'Autorizza' sul telefono"
Write-Host " - accedi con il tuo Apple ID e trascina dentro $ipa, poi Installa"
Write-Host " - sull'iPhone: Impostazioni > Generali > VPN e gestione dispositivi > autorizza il tuo Apple ID"
Write-Host " - Nomorediet > Profilo > Apple Salute > Collega: attiva Passi e Peso"
Start-Process $impactor
explorer $dir
