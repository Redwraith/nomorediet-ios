# Crea il progetto Nomorediet su questo PC e apre Claude Code dentro, con le skill pronte.
#   irm https://raw.githubusercontent.com/Redwraith/nomorediet-ios/main/scripts/windows/progetto.ps1 | iex
$ErrorActionPreference = "Stop"
$dest = Join-Path $env:USERPROFILE "nomorediet-ios"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
if (Test-Path (Join-Path $dest ".git")) { git -C $dest pull --ff-only } else { git clone https://github.com/Redwraith/nomorediet-ios.git $dest }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    irm https://claude.ai/install.ps1 | iex
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User") + ";" + (Join-Path $env:USERPROFILE ".local\bin")
}
Set-Location $dest
Write-Host "`nProgetto in $dest. Avvio Claude Code: scrivi per esempio" -ForegroundColor Green
Write-Host '  "prepara il PC, installa Nomorediet con Impactor e fai il debug di Apple Salute"'
claude
