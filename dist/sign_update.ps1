<#
.SYNOPSIS
  Подписывает установщик закрытым DSA-ключом ровно так, как это делает
  собственный sign_update.bat из WinSparkle:

      openssl dgst -sha1 -binary < file | openssl dgst -sha1 -sign key | openssl enc -base64

.DESCRIPTION
  Печатает три числа, которые идут в <enclosure> файла dist/appcast.xml:
  length, nimbus:sha256 и sparkle:dsaSignature.

  Пересобрали exe — все три устарели. Не обновить их значит выпустить
  обновление, которое WinSparkle молча откажется ставить: подпись не сойдётся,
  и пользователь не увидит даже ошибки.

  Закрытый ключ dsa_priv.pem лежит в корне проекта и в git не попадает.
  Держите резервную копию: без него ни одна установленная копия больше
  никогда не обновится.

.EXAMPLE
  .\dist\sign_update.ps1 .\dist\out\NexusNimbus-Setup-0.1.0.exe
  .\dist\sign_update.ps1 <файл> -PrivateKey C:\backup\dsa_priv.pem
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$File,
  [string]$PrivateKey = (Join-Path $PSScriptRoot '..\dsa_priv.pem'),
  [string]$OpenSsl = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $File))       { throw "Файла нет: $File" }
if (-not (Test-Path $PrivateKey)) { throw "Закрытого ключа нет: $PrivateKey (как создать — см. dist/README.md)" }

# openssl: сначала из PATH, потом тот, что идёт с Git for Windows.
if (-not $OpenSsl) {
  $cmd = Get-Command openssl -ErrorAction SilentlyContinue
  if ($cmd) { $OpenSsl = $cmd.Source }
  elseif (Test-Path 'C:\Program Files\Git\usr\bin\openssl.exe') { $OpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
  else { throw 'openssl не найден. Поставьте его или укажите -OpenSsl <путь>.' }
}

$File = (Resolve-Path $File).Path
$PrivateKey = (Resolve-Path $PrivateKey).Path

# Три шага гоняем через временные файлы: PowerShell портит двоичные данные
# в конвейере, превращая их в текст.
$tmp1 = [System.IO.Path]::GetTempFileName()
$tmp2 = [System.IO.Path]::GetTempFileName()
try {
  & $OpenSsl dgst -sha1 -binary -out $tmp1 $File
  & $OpenSsl dgst -sha1 -sign $PrivateKey -out $tmp2 $tmp1
  $sig = & $OpenSsl enc -base64 -A -in $tmp2
} finally {
  Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
}

$len = (Get-Item $File).Length
$sha = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()

Write-Host ''
Write-Host "Файл:                 $File"
Write-Host "length:               $len"
Write-Host "nimbus:sha256:        $sha"
Write-Host "sparkle:dsaSignature: $sig"

# Возвращаем объект, чтобы release.ps1 мог подставить значения в appcast сам.
[pscustomobject]@{
  Path      = $File
  Length    = $len
  Sha256    = $sha
  Signature = $sig
}
