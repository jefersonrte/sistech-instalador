# SISTECH - desinstalar (PowerShell como administrador):
#   irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/desinstalar.ps1 | iex
# Faz um ultimo backup dos bancos e remove servicos, tarefa, atalho, regras de firewall e C:\sistech, MENOS C:\sistech\backup.
& {
$ErrorActionPreference = 'Stop'; $Raiz = 'C:\sistech'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'abra o PowerShell como administrador.' }
if ((Get-Service SISTECH-Banco -ErrorAction SilentlyContinue) -and (Test-Path "$Raiz\backup.ps1")) {
  Write-Host '>> Ultimo backup dos bancos'; Start-Service SISTECH-Banco; Start-Sleep 3
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\backup.ps1"
}
foreach ($s in 'SISTECH-Web', 'SISTECH-Banco') {
  if (Get-Service $s -ErrorAction SilentlyContinue) { Stop-Service $s -Force -ErrorAction SilentlyContinue; & sc.exe delete $s | Out-Null; Write-Host ">> servico $s removido" }
}
Unregister-ScheduledTask -TaskName 'SISTECH - Backup' -Confirm:$false -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'SISTECH*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Remove-Item "$env:PUBLIC\Desktop\SISTECH.url" -ErrorAction SilentlyContinue
Start-Sleep 2
if (Test-Path $Raiz) { Get-ChildItem $Raiz -Force | Where-Object Name -ne 'backup' | Remove-Item -Recurse -Force }
Write-Host "SISTECH removido. Os backups ficaram em $Raiz\backup (apague a pasta se nao precisar mais)." -ForegroundColor Green
}
