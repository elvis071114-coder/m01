# M-01 Companion one-line installer for Windows: downloads the app package from this site and runs its installer.
# It only installs the app itself; the AI is set up inside the app. (ASCII only on purpose, so it reads correctly through irm | iex.)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = 'https://elvis071114-coder.github.io/m01/downloads/M-01-Companion-Windows.zip'
$tmp = Join-Path $env:TEMP ('m01-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Write-Host ([regex]::Unescape('\u4e0b\u8f09 M-01 Companion\u2026 / Downloading M-01 Companion\u2026')) -ForegroundColor Yellow
$ProgressPreference = 'SilentlyContinue'
try {
  Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp 'm01.zip') -UseBasicParsing
  Expand-Archive -LiteralPath (Join-Path $tmp 'm01.zip') -DestinationPath (Join-Path $tmp 'app') -Force
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'app\install.ps1')
} catch {
  Write-Host ([regex]::Unescape('\u5b89\u88dd\u6c92\u6709\u5b8c\u6210\uff0c\u8acb\u6539\u7528\u7db2\u9801\u4e0a\u7684\u300c\u4e0b\u8f09 Windows \u7248\u300d\u3002 / The install did not finish \u2014 use the Download for Windows button instead.')) -ForegroundColor Red
  Write-Host $_.Exception.Message
} finally {
  $ProgressPreference = 'Continue'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
