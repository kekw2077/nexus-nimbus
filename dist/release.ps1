<#
.SYNOPSIS
  Выпуск версии Nexus Nimbus одной командой: сборка, установщик, подпись и
  запись в appcast.xml.

.DESCRIPTION
  Делает по порядку:
    1. поднимает version: в pubspec.yaml (номер сборки +1);
    2. flutter build windows --release;
    3. ISCC.exe dist\installer.iss -> dist\out\NexusNimbus-Setup-<версия>.exe;
    4. подписывает установщик (dist\sign_update.ps1);
    5. вставляет <item> первым в dist\appcast.xml с реальными length,
       sha256 и подписью.

  Выкладку делает отдельный скрипт: publish-to-github.ps1 или
  publish-to-station.ps1. Разделено намеренно — так можно собрать и проверить
  установщик, ничего никуда не выложив.

.EXAMPLE
  .\dist\release.ps1 -Version 0.2.0 -Notes "Корзина", "Публичные ссылки"
  .\dist\release.ps1 -Version 0.2.0 -SkipBuild     # exe уже собран
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  [string[]]$Notes = @(),

  [switch]$SkipBuild,

  [string]$Iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $root 'dist'

function Step($text) { Write-Host "`n=== $text" -ForegroundColor Cyan }

# --- 1. Версия в pubspec -----------------------------------------------------
Step "Версия $Version"
$pubspecPath = Join-Path $root 'pubspec.yaml'
$pubspec = Get-Content $pubspecPath -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
  throw 'Не разобрал строку version: в pubspec.yaml'
}
$build = [int]$Matches[2]
if ($Matches[1] -ne $Version) { $build++ }
$pubspec = $pubspec -replace '(?m)^version:.*$', "version: $Version+$build"
Set-Content $pubspecPath $pubspec -NoNewline
Write-Host "pubspec.yaml -> $Version+$build"

# --- 2. Сборка ---------------------------------------------------------------
if (-not $SkipBuild) {
  Step 'flutter build windows --release'
  Push-Location $root
  try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "Сборка не прошла (код $LASTEXITCODE)" }
  } finally { Pop-Location }
}

$exe = Join-Path $root 'build\windows\x64\runner\Release\nexus_nimbus.exe'
if (-not (Test-Path $exe)) { throw "Нет собранного exe: $exe" }

# --- 3. Установщик -----------------------------------------------------------
Step 'Установщик (Inno Setup)'
if (-not (Test-Path $Iscc)) {
  throw "ISCC.exe не найден: $Iscc. Поставьте Inno Setup 6 или укажите -Iscc <путь>."
}
& $Iscc (Join-Path $dist 'installer.iss') "/DAppVersion=$Version" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Inno Setup вернул код $LASTEXITCODE" }

$setup = Join-Path $dist "out\NexusNimbus-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "Установщик не появился: $setup" }
Write-Host ("Готово: {0} ({1:N1} МБ)" -f $setup, ((Get-Item $setup).Length / 1MB))

# --- 4. Подпись --------------------------------------------------------------
Step 'Подпись обновления'
$signed = & (Join-Path $dist 'sign_update.ps1') $setup

# --- 5. Запись в appcast -----------------------------------------------------
Step 'Запись в appcast.xml'
$appcastPath = Join-Path $dist 'appcast.xml'
$appcast = Get-Content $appcastPath -Raw

$marker = '<!-- NIMBUS:NEXT-RELEASE -->'
if ($appcast -notmatch [regex]::Escape($marker)) {
  throw "В appcast.xml нет строки-метки $marker — вставлять запись некуда."
}
if ($appcast -match "sparkle:version=`"$([regex]::Escape($Version))`"") {
  throw "Версия $Version уже есть в appcast.xml. Поднимите номер или уберите старую запись."
}

if ($Notes.Count -eq 0) { $Notes = @("Обновление $Version") }
$items = ($Notes | ForEach-Object { "          <li>$([System.Security.SecurityElement]::Escape($_))</li>" }) -join "`n"

# Ссылка пишется на GitHub Releases; publish-to-station.ps1 при выкладке на
# станцию перепишет её на адрес станции сам.
$url = "https://github.com/kekw2077/nexus-nimbus/releases/download/v$Version/NexusNimbus-Setup-$Version.exe"
$pubDate = (Get-Date).ToUniversalTime().ToString('ddd, dd MMM yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + ' +0000'

$item = @"
    <item>
      <title>Nexus Nimbus $Version</title>
      <pubDate>$pubDate</pubDate>
      <sparkle:version>$Version</sparkle:version>
      <sparkle:shortVersionString>$Version</sparkle:shortVersionString>
      <description><![CDATA[
        <style>
          html,body{background:#07080C;color:#C7CBD6;margin:0;padding:14px 18px;
            font-family:'Segoe UI',Roboto,sans-serif;font-size:14px;line-height:1.5;}
          h1,h2,h3,b,strong{color:#F2F4F8;}
          a{color:#3F63D1;}
          ul{margin:6px 0;padding-left:20px;}
          li{margin:5px 0;}
        </style>
        <ul>
$items
        </ul>
      ]]></description>
      <enclosure
        url="$url"
        sparkle:version="$Version"
        sparkle:os="windows"
        length="$($signed.Length)"
        type="application/octet-stream"
        sparkle:dsaSignature="$($signed.Signature)"
        nimbus:sha256="$($signed.Sha256)" />
    </item>

    $marker
"@

# Подставляем строкой, а не -replace: в подписи и заметках попадаются $ и \,
# которые оператор замены принял бы за ссылки на группы.
$at = $appcast.IndexOf($marker)
$appcast = $appcast.Substring(0, $at) + $item.TrimStart() + $appcast.Substring($at + $marker.Length)
Set-Content $appcastPath $appcast -NoNewline -Encoding UTF8

Write-Host "appcast.xml дополнен записью $Version"
Write-Host ''
Write-Host 'Дальше:' -ForegroundColor Green
Write-Host "  .\dist\publish-to-github.ps1 -Version $Version    # выложить в GitHub Releases"
Write-Host "  .\dist\publish-to-station.ps1 -Version $Version   # выложить на станцию"
