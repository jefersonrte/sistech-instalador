# SISTECH - atualizar (PowerShell como administrador):
#   irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/atualizar.ps1 | iex
# Compara a versao instalada com a ultima publicada; se houver nova, roda o instalar.ps1 (backup dos bancos antes,
# mesmas portas e mesma opcao de rede da instalacao). $env:SISTECH_FORCAR = '1' reinstala mesmo sem versao nova.
& {
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Raiz = 'C:\sistech'
$Repo = if ($env:SISTECH_REPO) { $env:SISTECH_REPO } else { 'jefersonrte/sistech-instalador' }
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'ERRO: abra o PowerShell como administrador e rode o comando de novo.' -ForegroundColor Red; return }
if (-not (Test-Path "$Raiz\app\.env")) {
  Write-Host "ERRO: o SISTECH nao esta instalado em $Raiz. Para instalar use o instalar.ps1." -ForegroundColor Red; return }
$atual = if (Test-Path "$Raiz\app\VERSAO.txt") { (Get-Content "$Raiz\app\VERSAO.txt" -Raw).Trim() } else { '?' }
$nova = (Invoke-WebRequest "https://github.com/$Repo/releases/latest/download/VERSAO.txt" -UseBasicParsing).Content
if ($nova -is [byte[]]) { $nova = [Text.Encoding]::ASCII.GetString($nova) }; $nova = $nova.Trim()
Write-Host "SISTECH instalado: $atual    ultima versao: $nova"
if ($atual -eq $nova -and $env:SISTECH_FORCAR -ne '1') { Write-Host 'Ja esta na ultima versao. Nada a fazer.' -ForegroundColor Green; return }
Invoke-Expression (Invoke-WebRequest "https://raw.githubusercontent.com/$Repo/main/instalar.ps1" -UseBasicParsing).Content
}
