<#
.SYNOPSIS
  Выкладывает выпуск в GitHub Releases и обновляет канал обновлений.

.DESCRIPTION
  1. создаёт (или дополняет) релиз v<версия> и кладёт в него установщик;
  2. коммитит dist/appcast.xml в ветку main и пушит — приложение читает
     именно этот файл через raw.githubusercontent;
  3. проверяет, что и файл канала, и установщик действительно отдаются
     анонимно. Без этой проверки легко выложить обновление, которое никто
     не получит: приватный репозиторий отдаёт 404 вместо файла.

  Репозиторий обязан быть публичным — WinSparkle не умеет авторизоваться.

.EXAMPLE
  .\dist\publish-to-github.ps1 -Version 0.2.0
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$Repo = 'kekw2077/nexus-nimbus',
  [string]$Branch = 'main',

  # Не пушить, только собрать релиз — на случай ручной проверки.
  [switch]$NoCommit
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $root 'dist'
$setup = Join-Path $dist "out\NexusNimbus-Setup-$Version.exe"

function Step($text) { Write-Host "`n=== $text" -ForegroundColor Cyan }

if (-not (Test-Path $setup)) {
  throw "Нет установщика $setup. Сначала: .\dist\release.ps1 -Version $Version"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw 'Нужен gh (GitHub CLI): https://cli.github.com'
}

# --- Релиз -------------------------------------------------------------------
Step "Релиз v$Version в $Repo"
$exists = $false
try {
  gh release view "v$Version" --repo $Repo *> $null
  $exists = ($LASTEXITCODE -eq 0)
} catch { $exists = $false }

if ($exists) {
  Write-Host "Релиз уже есть — заменяю файл."
  gh release upload "v$Version" $setup --repo $Repo --clobber
} else {
  gh release create "v$Version" $setup `
    --repo $Repo `
    --title "Nexus Nimbus $Version" `
    --notes "Установщик для Windows. Обновление придёт само тем, у кого программа уже стоит."
}
if ($LASTEXITCODE -ne 0) { throw "gh вернул код $LASTEXITCODE" }

# --- Канал -------------------------------------------------------------------
if (-not $NoCommit) {
  Step 'Публикация appcast.xml'
  Push-Location $root
  try {
    git add dist/appcast.xml pubspec.yaml
    git commit -m "Выпуск $Version" | Out-Host
    git push origin $Branch | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git push вернул код $LASTEXITCODE" }
  } finally { Pop-Location }
}

# --- Проверка ----------------------------------------------------------------
Step 'Проверка: файлы действительно отдаются'
$feed = "https://raw.githubusercontent.com/$Repo/$Branch/dist/appcast.xml"
$asset = "https://github.com/$Repo/releases/download/v$Version/NexusNimbus-Setup-$Version.exe"

# raw.githubusercontent кэширует до пяти минут — свежий коммит может
# ответить прошлым содержимым. Ждём, пока в канале появится нужная версия.
$deadline = (Get-Date).AddMinutes(6)
$seen = $false
while ((Get-Date) -lt $deadline) {
  try {
    $xml = (Invoke-WebRequest -Uri $feed -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }).Content
    if ($xml -match [regex]::Escape("<sparkle:version>$Version</sparkle:version>")) { $seen = $true; break }
  } catch {}
  Start-Sleep -Seconds 15
  Write-Host '.' -NoNewline
}
Write-Host ''
if ($seen) { Write-Host "Канал отдаёт версию $Version" -ForegroundColor Green }
else { Write-Warning "В канале ещё нет $Version. Кэш raw.githubusercontent живёт до 5 минут — проверьте позже: $feed" }

try {
  $head = Invoke-WebRequest -Uri $asset -Method Head -UseBasicParsing -MaximumRedirection 5
  Write-Host ("Установщик отдаётся: {0:N1} МБ" -f ($head.Headers['Content-Length'][0] / 1MB)) -ForegroundColor Green
} catch {
  throw "Установщик по ссылке не скачивается: $asset`nЕсли репозиторий приватный, обновления работать не будут."
}

Write-Host ''
Write-Host 'Готово. Установленные копии подхватят обновление сами.' -ForegroundColor Green
Write-Host "Канал: $feed"
