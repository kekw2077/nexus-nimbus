<#
.SYNOPSIS
  Второй канал: выложить обновление на домашнюю станцию вместо GitHub.

.DESCRIPTION
  Кладёт установщик и appcast.xml на станцию по SSH, ПЕРЕПИСАВ в канале
  ссылки с GitHub на адрес станции. Без этой перезаписи вышло бы бессмысленное:
  список версий читается по локальной сети, а сами файлы всё равно качаются
  из интернета.

  Подпись установщика не трогается: она считается по содержимому файла,
  а не по месту хранения, и переезжает вместе с ним.

  Раздача идёт тем же статическим сервером на порту 8099, что и у Anima,
  только из подпапки nimbus — отдельный сервер поднимать не нужно.

  Чтобы приложение пошло на станцию, в настройках выберите «Свой сервер»
  и впишите тот же адрес, что в -BaseUrl.

.EXAMPLE
  .\dist\publish-to-station.ps1 -Version 0.2.0
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  # Имя хоста из ~/.ssh/config.
  [string]$SshHost = 'npc',

  # Что писать В ФАЙЛАХ — по этому адресу приложение пойдёт за обновлением.
  [string]$BaseUrl = 'http://100.79.130.7:8099/nimbus',

  # Куда класть на станции. Подпапка того же каталога, что раздаёт Anima.
  [string]$Remote = '/home/art/evs-updates/files/nimbus',

  # Сколько установщиков хранить на станции.
  [int]$Keep = 3
)

$ErrorActionPreference = 'Stop'
$dist = $PSScriptRoot
$setup = Join-Path $dist "out\NexusNimbus-Setup-$Version.exe"

function Step($text) { Write-Host "`n=== $text" -ForegroundColor Cyan }

if (-not (Test-Path $setup)) {
  throw "Нет установщика $setup. Сначала: .\dist\release.ps1 -Version $Version"
}

# --- Канал с переписанными ссылками -----------------------------------------
Step 'Готовлю appcast для станции'
$xml = Get-Content (Join-Path $dist 'appcast.xml') -Raw
$xml = [regex]::Replace(
  $xml,
  'https://github\.com/[^"]*?/releases/download/[^"/]+/(NexusNimbus-Setup-[^"]+\.exe)',
  { param($m) "$BaseUrl/$($m.Groups[1].Value)" })

$tmp = Join-Path $env:TEMP 'nimbus-appcast-station.xml'
Set-Content $tmp $xml -Encoding UTF8 -NoNewline

# --- Отправка ----------------------------------------------------------------
Step ("Отправляю установщик ({0:N1} МБ)" -f ((Get-Item $setup).Length / 1MB))
ssh $SshHost "mkdir -p '$Remote'"
if ($LASTEXITCODE -ne 0) { throw "Не достучался до станции $SshHost" }

scp -q $setup "${SshHost}:${Remote}/"
if ($LASTEXITCODE -ne 0) { throw 'scp не смог отправить установщик' }
scp -q $tmp "${SshHost}:${Remote}/appcast.xml"
if ($LASTEXITCODE -ne 0) { throw 'scp не смог отправить appcast.xml' }

# --- Уборка старого ----------------------------------------------------------
Step "Оставляю последние $Keep установщиков"
ssh $SshHost "cd '$Remote' && ls -1t NexusNimbus-Setup-*.exe 2>/dev/null | tail -n +$($Keep + 1) | xargs -r rm -f"

# --- Проверка ----------------------------------------------------------------
Step 'Проверка: станция действительно отдаёт файлы'
$feed = "$BaseUrl/appcast.xml"
$asset = "$BaseUrl/NexusNimbus-Setup-$Version.exe"

try {
  $got = (Invoke-WebRequest -Uri $feed -UseBasicParsing -TimeoutSec 20).Content
  if ($got -notmatch [regex]::Escape("<sparkle:version>$Version</sparkle:version>")) {
    throw "Станция отдаёт канал, но версии $Version в нём нет"
  }
  Write-Host "Канал отдаётся и содержит $Version" -ForegroundColor Green
} catch {
  throw "Канал не читается: $feed`n$_"
}

try {
  $head = Invoke-WebRequest -Uri $asset -Method Head -UseBasicParsing -TimeoutSec 20
  Write-Host ("Установщик отдаётся: {0:N1} МБ" -f ($head.Headers['Content-Length'][0] / 1MB)) -ForegroundColor Green
} catch {
  throw "Установщик не скачивается: $asset"
}

Write-Host ''
Write-Host 'Готово. В настройках приложения: «Откуда брать» -> «Свой сервер»,' -ForegroundColor Green
Write-Host "адрес: $BaseUrl"
