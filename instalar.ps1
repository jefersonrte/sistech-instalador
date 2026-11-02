# SISTECH - instalador para Windows 10/11 (loja + emissor de NFS-e + banco, tudo em C:\sistech, sem Docker).
# PowerShell como administrador:
#   irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/instalar.ps1 | iex
# Rodar de novo = atualizar (faz backup dos bancos antes e mantem os dados); ou atualizar.ps1, que so roda se houver versao nova.
# Opcoes (antes do comando):  $env:SISTECH_PORTA = '8094'  (loja; o emissor usa a porta seguinte, ou $env:SISTECH_PORTA_EMISSOR)
#   $env:SISTECH_REDE = '0' (so este computador; padrao '1' = rede local). Ficam gravadas em C:\sistech\config\opcoes.txt.
#   Banco existente da loja: dump em C:\sistech\importar\ (*.sql ou *.sql.gz) e a chave do app em C:\sistech\importar\APP_KEY.txt
#   (sem a chave os CPF/CNPJ criptografados do dump nao abrem). So e importado quando o banco ainda esta vazio.
# A loja e o emissor ja saem conectados entre si (chaves geradas aqui); a NFS-e sai do proprio PDV. O emissor comeca em
# "simulacao" (sem valor fiscal): para homologacao/producao, certificado e ambiente em C:\sistech\emissor\.env.
# Mensagens sem acento de proposito: o script roda em PowerShell 5.1 com qualquer codificacao.
& {
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz = 'C:\sistech'
$Repo = if ($env:SISTECH_REPO) { $env:SISTECH_REPO } else { 'jefersonrte/sistech-instalador' }
$Origem = if ($env:SISTECH_ORIGEM) { $env:SISTECH_ORIGEM.TrimEnd('/') } else { "https://github.com/$Repo/releases/latest/download" }
# portas e rede: o que vier no ambiente; senao o que a instalacao anterior gravou em config\opcoes.txt; senao o padrao
$Gravado = @{}; if (Test-Path "$Raiz\config\opcoes.txt") { Get-Content "$Raiz\config\opcoes.txt" | ForEach-Object { $k, $v = $_ -split '=', 2; if ($v) { $Gravado[$k.Trim()] = $v.Trim() } } }
$Porta = if ($env:SISTECH_PORTA) { [int]$env:SISTECH_PORTA } elseif ($Gravado.PORTA) { [int]$Gravado.PORTA } else { 8094 }
$PortaEmissor = if ($env:SISTECH_PORTA_EMISSOR) { [int]$env:SISTECH_PORTA_EMISSOR } elseif ($Gravado.PORTA_EMISSOR) { [int]$Gravado.PORTA_EMISSOR } else { $Porta + 1 }
$Rede = if ($env:SISTECH_REDE) { $env:SISTECH_REDE -eq '1' } elseif ($Gravado.REDE) { $Gravado.REDE -eq '1' } else { $true }   # padrao: rede local
$PortaBanco = 3307
$SvcBanco = 'SISTECH-Banco'; $SvcWeb = 'SISTECH-Web'
$Admins = '*S-1-5-32-544'; $Sistema = '*S-1-5-18'   # por SID: funciona em Windows de qualquer idioma
$Apps = @('app', 'emissor')                         # loja e emissor de NFS-e (dois apps Laravel no mesmo Apache)

function Passo($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Falha($t) { Write-Host "`nERRO: $t" -ForegroundColor Red; throw $t }
function Senha([int]$n = 24) {
  $c = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'; $b = New-Object byte[] $n
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $c[$_ % $c.Length] })
}
function ChaveApp { $k = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($k); 'base64:' + [Convert]::ToBase64String($k) }
# programa externo: no PowerShell 5.1, stderr redirecionado vira erro fatal com Stop; aqui so vale o codigo de saida
function Exe($exe) { $e = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe @args 2>&1; $script:Codigo = $LASTEXITCODE } finally { $ErrorActionPreference = $e }
  $script:Erro = ($o | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' '
  $o | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } }   # devolve so a saida normal
function Icacls { & icacls.exe @args | Out-Null; if ($LASTEXITCODE) { Falha "icacls $($args -join ' ')" } }
function Gz2Sql($gz, $sql) {
  $i = [IO.File]::OpenRead($gz); $z = New-Object IO.Compression.GZipStream($i, [IO.Compression.CompressionMode]::Decompress)
  $o = [IO.File]::Create($sql); $z.CopyTo($o); $o.Close(); $z.Close(); $i.Close()
}
function Sql2Gz($sql, $gz) {
  $i = [IO.File]::OpenRead($sql); $o = [IO.File]::Create($gz); $z = New-Object IO.Compression.GZipStream($o, [IO.Compression.CompressionLevel]::Optimal)
  $i.CopyTo($z); $z.Close(); $o.Close(); $i.Close()
}
function Banco([string]$sql, [string]$base = '') {
  $env:MYSQL_PWD = $script:RootSenha
  $a = @('-uroot', '--host=127.0.0.1', "-P$PortaBanco", '--default-character-set=utf8mb4', '-N', '-e', $sql); if ($base) { $a += $base }
  $r = Exe "$Raiz\mariadb\bin\mariadb.exe" @a; $ok = $script:Codigo; Remove-Item Env:MYSQL_PWD
  if ($ok) { Falha "banco: $($script:Erro) $r" }; $r
}
function Dump([string]$base, [string]$arquivoGz) {
  $sql = "$Raiz\tmp\$base.sql"; $env:MYSQL_PWD = $script:RootSenha
  Exe "$Raiz\mariadb\bin\mariadb-dump.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" --single-transaction --routines --triggers --default-character-set=utf8mb4 "--result-file=$sql" $base | Out-Null
  $ok = $script:Codigo; Remove-Item Env:MYSQL_PWD; if ($ok) { Falha "o backup do banco $base falhou; nada foi alterado. $($script:Erro)" }
  Sql2Gz $sql $arquivoGz; Remove-Item $sql
}
# Artisan 'app' migrate --force   |   Artisan 'emissor' config:cache
function Artisan($pasta) { Push-Location "$Raiz\$pasta"; try { & "$Raiz\php\php.exe" artisan @args --no-interaction; if ($LASTEXITCODE) { Falha "artisan ($pasta) $($args -join ' ')" } } finally { Pop-Location } }
function ParaServico($n) { $s = Get-Service $n -ErrorAction SilentlyContinue; if ($s -and $s.Status -ne 'Stopped') { Stop-Service $n -Force; $s.WaitForStatus('Stopped', '00:01:00') } }
# servicos rodam em conta virtual (NT SERVICE\nome): sem senha, sem acesso a nada alem do que as permissoes abaixo liberam
function ContaServico($n) {
  & sc.exe config $n obj= "NT SERVICE\$n" | Out-Null; if ($LASTEXITCODE) { Falha "sc config $n" }
  & sc.exe failure $n reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null }
# .env a partir do .env.example: substitui as chaves informadas e acrescenta as que faltam (sem BOM)
function EscreveEnv($pasta, [Collections.Specialized.OrderedDictionary]$v) {
  $linhas = Get-Content "$Raiz\$pasta\.env.example" -Encoding UTF8 | ForEach-Object { $k = ($_ -split '=', 2)[0]; if ($v.Contains($k)) { "$k=$($v[$k])"; $v.Remove($k) } else { $_ } }
  $linhas += $v.Keys | ForEach-Object { "$_=$($v[$_])" }
  [IO.File]::WriteAllLines("$Raiz\$pasta\.env", [string[]]$linhas, (New-Object Text.UTF8Encoding $false))
}

# --- 0. conferencias ---------------------------------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Falha 'abra o PowerShell como administrador (botao direito > Executar como administrador) e rode o comando de novo.' }
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Build -lt 17763) { Falha 'precisa de Windows 10/11 de 64 bits.' }
if ((Get-PSDrive C).Free -lt 2GB) { Falha 'precisa de pelo menos 2 GB livres no disco C:.' }
if ($Porta -eq $PortaEmissor) { Falha 'a porta da loja e a do emissor precisam ser diferentes.' }
$Atualizando = Test-Path "$Raiz\app\.env"
foreach ($p in @($Porta, $PortaEmissor, $PortaBanco)) {
  $uso = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($uso) { $dono = (Get-Process -Id $uso.OwningProcess -ErrorAction SilentlyContinue).Path
    if ($dono -notlike "$Raiz\*") { Falha "a porta $p ja esta em uso por $dono. Escolha outra com `$env:SISTECH_PORTA (e `$env:SISTECH_PORTA_EMISSOR)." } }
}
Write-Host "SISTECH - $(if ($Atualizando) { 'atualizacao' } else { 'instalacao' }) em $Raiz (loja na porta $Porta, emissor na $PortaEmissor, $(if ($Rede) { 'rede local' } else { 'so este computador' }))"

# --- 1. pastas (so administradores; os servicos ganham acesso so ao que precisam) ---------------------------------------
Passo 'Preparando C:\sistech'
foreach ($d in 'config', 'dados', 'backup', 'importar', 'logs\web', 'logs\banco', 'tmp\web', 'tmp\banco', 'baixados') { New-Item -ItemType Directory -Force "$Raiz\$d" | Out-Null }
# sem /T: as subpastas herdam; icacls propaga as permissoes herdaveis sozinho
Icacls $Raiz /inheritance:r /grant:r "${Admins}:(OI)(CI)F" "${Sistema}:(OI)(CI)F"

# --- 2. downloads conferidos pelo SHA-256 -------------------------------------------------------------------------------
Passo "Baixando de $Origem"
$B = "$Raiz\baixados"
Invoke-WebRequest "$Origem/SHA256SUMS.txt" -OutFile "$B\SHA256SUMS.txt" -UseBasicParsing
Invoke-WebRequest "$Origem/VERSAO.txt" -OutFile "$B\VERSAO.txt" -UseBasicParsing
$Versao = (Get-Content "$B\VERSAO.txt" -Raw).Trim()
$Hash = @{}; Get-Content "$B\SHA256SUMS.txt" | ForEach-Object { $h, $n = $_ -split '\s+\*?', 2; if ($n) { $Hash[$n.Trim()] = $h.ToLower() } }
function Baixa($n) {
  $f = "$B\$n"
  if (-not ((Test-Path $f) -and (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -eq $Hash[$n])) {
    Write-Host "   $n"; Invoke-WebRequest "$Origem/$n" -OutFile $f -UseBasicParsing }
  if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -ne $Hash[$n]) { Remove-Item $f; Falha "o arquivo $n veio diferente do publicado (SHA-256). Nada foi alterado." }
  $f
}
$ZipApp = Baixa 'sistech-app.zip'; $ZipEmissor = Baixa 'sistech-emissor.zip'; $ZipRt = Baixa 'sistech-runtime.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- 3. Visual C++ (exigido por PHP, Apache e MariaDB) ------------------------------------------------------------------
$vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
if (-not $vc -or $vc.Installed -ne 1 -or $vc.Bld -lt 33810) {
  Passo 'Instalando o Visual C++ da Microsoft'
  $vce = Baixa 'vc_redist.x64.exe'; $sig = Get-AuthenticodeSignature $vce
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Falha 'assinatura do vc_redist invalida.' }
  $p = Start-Process $vce '/install /quiet /norestart' -Wait -PassThru; if ($p.ExitCode -notin 0, 1638, 3010) { Falha "vc_redist saiu com $($p.ExitCode)" }
}

# --- 4. backup antes de mexer (atualizacao) -----------------------------------------------------------------------------
$RootArq = "$Raiz\config\banco-root.txt"
if (Test-Path $RootArq) { $script:RootSenha = (Get-Content $RootArq -Raw).Trim() }
if ($Atualizando -and (Get-Service $SvcBanco -ErrorAction SilentlyContinue)) {
  Passo 'Guardando uma copia dos bancos antes de atualizar'
  Start-Service $SvcBanco; Start-Sleep 3
  $quando = Get-Date -f yyyyMMdd-HHmmss
  Dump 'sistech' "$Raiz\backup\sistech-antes-$Versao-$quando.sql.gz"
  if ((Banco "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='sistech_emissor'") -eq '1') { Dump 'sistech_emissor' "$Raiz\backup\sistech-emissor-antes-$Versao-$quando.sql.gz" }
}

# --- 5. PHP, Apache e MariaDB --------------------------------------------------------------------------------------------
$RtNovo = ([IO.Compression.ZipFile]::OpenRead($ZipRt)).Entries | Where-Object FullName -eq 'RUNTIME.txt' | ForEach-Object { (New-Object IO.StreamReader($_.Open())).ReadToEnd() }
$RtAtual = if (Test-Path "$Raiz\RUNTIME.txt") { (Get-Content "$Raiz\RUNTIME.txt" -Raw).Trim() }
ParaServico $SvcWeb
if ($RtNovo -ne $RtAtual) {
  Passo 'Instalando PHP, Apache e MariaDB'
  ParaServico $SvcBanco
  $t = "$Raiz\tmp\runtime"; if (Test-Path $t) { Remove-Item $t -Recurse -Force }
  [IO.Compression.ZipFile]::ExtractToDirectory($ZipRt, $t)
  foreach ($d in 'php', 'apache', 'mariadb') { if (Test-Path "$Raiz\$d") { Remove-Item "$Raiz\$d" -Recurse -Force }; Move-Item "$t\$d" "$Raiz\$d" }
  Move-Item "$t\RUNTIME.txt" "$Raiz\RUNTIME.txt" -Force; Remove-Item $t -Recurse -Force
}

# configuracoes enxutas (regravadas a cada execucao)
$R = $Raiz -replace '\\', '/'
@"
[mysqld]
datadir=$R/dados
port=$PortaBanco
bind-address=127.0.0.1
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
log-error=$R/logs/banco/erro.log
secure_file_priv=$R/tmp/banco
local_infile=0
performance_schema=OFF
max_connections=60
innodb_buffer_pool_size=128M
key_buffer_size=8M
table_open_cache=400
tmp_table_size=16M
max_heap_table_size=16M
[client]
port=$PortaBanco
"@ | Set-Content "$Raiz\config\my.ini" -Encoding ASCII

$exts = 'curl', 'fileinfo', 'mbstring', 'openssl', 'pdo_mysql', 'sodium', 'zip', 'intl', 'gd', 'exif'
@"
[PHP]
engine=On
expose_php=Off
display_errors=Off
display_startup_errors=Off
log_errors=On
error_log="$R/logs/web/php.log"
error_reporting=E_ALL & ~E_DEPRECATED
memory_limit=256M
max_execution_time=120
post_max_size=25M
upload_max_filesize=20M
max_file_uploads=20
allow_url_include=Off
enable_dl=Off
file_uploads=On
sys_temp_dir="$R/tmp/web"
upload_tmp_dir="$R/tmp/web"
session.save_path="$R/tmp/web"
session.cookie_httponly=1
session.use_strict_mode=1
date.timezone=America/Sao_Paulo
extension_dir="$R/php/ext"
$(($exts | ForEach-Object { "extension=$_" }) -join "`r`n")
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=30000
opcache.validate_timestamps=0
realpath_cache_size=4096K
realpath_cache_ttl=600
"@ | Set-Content "$Raiz\php\php.ini" -Encoding ASCII

$Bind = if ($Rede) { '0.0.0.0' } else { '127.0.0.1' }
# mesmo com o firewall aberto, o Apache so atende enderecos de rede local (nunca internet)
$Quem = if ($Rede) { 'Require ip 127.0.0.1 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 fc00::/7 fe80::/10' } else { 'Require all granted' }
function Site($pasta, $porta, $nome) { @"

# $nome
<VirtualHost *:$porta>
  ServerName localhost
  DocumentRoot "`${RAIZ}/$pasta/public"
  ErrorLog "`${RAIZ}/logs/web/$pasta-erro.log"
  CustomLog "`${RAIZ}/logs/web/$pasta-acesso.log" curto
  <Directory "`${RAIZ}/$pasta/public">
    Options -Indexes +FollowSymLinks
    AllowOverride None
    $Quem
    DirectoryIndex index.php
    RewriteEngine On
    RewriteCond %{HTTP:Authorization} .
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteRule ^ index.php [L]
  </Directory>
</VirtualHost>
"@ }
@"
Define RAIZ "$R"
ServerRoot "`${RAIZ}/apache"
Listen ${Bind}:$Porta
Listen ${Bind}:$PortaEmissor
ServerName localhost
PidFile "`${RAIZ}/logs/web/httpd.pid"
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule headers_module modules/mod_headers.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule setenvif_module modules/mod_setenvif.so
LoadModule filter_module modules/mod_filter.so
LoadModule deflate_module modules/mod_deflate.so
LoadModule expires_module modules/mod_expires.so
LoadModule php_module "`${RAIZ}/php/php8apache2_4.dll"
PHPIniDir "`${RAIZ}/php"
AddHandler application/x-httpd-php .php
TypesConfig conf/mime.types

ThreadsPerChild 64
MaxConnectionsPerChild 0
KeepAlive On
KeepAliveTimeout 5
Timeout 120
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
LimitRequestBody 26214400
AcceptFilter http none
AcceptFilter https none
EnableSendfile Off
EnableMMAP Off

ErrorLog "`${RAIZ}/logs/web/erro.log"
LogLevel warn
LogFormat "%h %t \"%r\" %>s %b %D" curto

<Directory />
  AllowOverride None
  Require all denied
</Directory>
<FilesMatch "^\.">
  Require all denied
</FilesMatch>
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/css text/plain application/javascript application/json image/svg+xml
</IfModule>
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresByType text/css "access plus 7 days"
  ExpiresByType application/javascript "access plus 7 days"
  ExpiresByType image/png "access plus 30 days"
  ExpiresByType image/svg+xml "access plus 30 days"
</IfModule>
$(Site 'app' $Porta 'SISTECH - loja')
$(Site 'emissor' $PortaEmissor 'SISTECH - emissor de NFS-e')
"@ | Set-Content "$Raiz\config\httpd.conf" -Encoding ASCII

# --- 6. servico do banco (conta virtual, so 127.0.0.1) -------------------------------------------------------------------
$NovoBanco = -not (Test-Path "$Raiz\dados\mysql")
if ($NovoBanco) {
  Passo 'Criando o banco de dados'
  $script:RootSenha = Senha 28; Set-Content $RootArq $script:RootSenha -Encoding ASCII -NoNewline
  Get-ChildItem "$Raiz\dados" -Force | Remove-Item -Recurse -Force
  $o = Exe "$Raiz\mariadb\bin\mariadb-install-db.exe" "--datadir=$Raiz\dados" "--password=$($script:RootSenha)" "--port=$PortaBanco"
  if ($script:Codigo) { Falha "mariadb-install-db falhou: $($script:Erro) $o" }
  Remove-Item "$Raiz\dados\my.ini" -ErrorAction SilentlyContinue
}
if (-not (Get-Service $SvcBanco -ErrorAction SilentlyContinue)) {
  New-Service $SvcBanco -BinaryPathName "`"$Raiz\mariadb\bin\mariadbd.exe`" --defaults-file=`"$Raiz\config\my.ini`" $SvcBanco" `
    -DisplayName 'SISTECH - Banco de dados' -Description 'MariaDB do SISTECH (somente 127.0.0.1)' -StartupType Automatic | Out-Null
}
ContaServico $SvcBanco
$SB = "NT SERVICE\$SvcBanco"
Icacls "$Raiz\dados" /grant "${SB}:(OI)(CI)M"
Icacls "$Raiz\logs\banco" /grant "${SB}:(OI)(CI)M"; Icacls "$Raiz\tmp\banco" /grant "${SB}:(OI)(CI)M"
Icacls "$Raiz\mariadb" /grant "${SB}:(OI)(CI)RX"; Icacls "$Raiz\config\my.ini" /grant "${SB}:R"
Start-Service $SvcBanco
$ok = $false; foreach ($i in 1..30) { $env:MYSQL_PWD = $script:RootSenha
  Exe "$Raiz\mariadb\bin\mariadb-admin.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" ping | Out-Null; $ok = $script:Codigo -eq 0; Remove-Item Env:MYSQL_PWD
  if ($ok) { break }; Start-Sleep 1 }
if (-not $ok) { Falha "o banco nao respondeu; veja $Raiz\logs\banco\erro.log" }
if (-not $NovoBanco -and $RtNovo -ne $RtAtual) { $env:MYSQL_PWD = $script:RootSenha
  Exe "$Raiz\mariadb\bin\mariadb-upgrade.exe" -uroot --host=127.0.0.1 "-P$PortaBanco" | Out-Null; Remove-Item Env:MYSQL_PWD }

# --- 7. aplicacoes (loja e emissor): troca o codigo mantendo .env e storage\app ------------------------------------------
Passo "Instalando o SISTECH $Versao (loja e emissor de NFS-e)"
foreach ($par in @(@('app', $ZipApp), @('emissor', $ZipEmissor))) {
  $pasta, $zip = $par
  $t = "$Raiz\tmp\$pasta-nova"; if (Test-Path $t) { Remove-Item $t -Recurse -Force }
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $t)
  if (Test-Path "$Raiz\$pasta") {
    Copy-Item "$Raiz\$pasta\.env" "$t\.env" -Force -ErrorAction SilentlyContinue
    if (Test-Path "$Raiz\$pasta\storage\app") { Remove-Item "$t\storage\app" -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item "$Raiz\$pasta\storage\app" "$t\storage\app" -Recurse }
    if (Test-Path "$Raiz\backup\$pasta-anterior") { Remove-Item "$Raiz\backup\$pasta-anterior" -Recurse -Force }
    Move-Item "$Raiz\$pasta" "$Raiz\backup\$pasta-anterior"
  }
  Move-Item $t "$Raiz\$pasta"
}

$NovaSenhaAdmin = $null; $NovoEmissor = -not (Test-Path "$Raiz\emissor\.env")
if (-not (Test-Path "$Raiz\app\.env")) {
  $chaveArq = "$Raiz\importar\APP_KEY.txt"
  $chave = if (Test-Path $chaveArq) { (Get-Content $chaveArq -Raw).Trim() } else { ChaveApp }
  if ($chave -notmatch '^base64:') { Falha 'APP_KEY.txt deve conter a linha base64:... do .env de origem.' }
  $SenhaApp = Senha 28
  Banco "CREATE DATABASE IF NOT EXISTS sistech CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'sistech'@'127.0.0.1' IDENTIFIED BY '$SenhaApp'; ALTER USER 'sistech'@'127.0.0.1' IDENTIFIED BY '$SenhaApp';
    GRANT ALL PRIVILEGES ON sistech.* TO 'sistech'@'127.0.0.1'; FLUSH PRIVILEGES;" | Out-Null
  EscreveEnv 'app' ([ordered]@{ APP_ENV = 'production'; APP_DEBUG = 'false'; APP_KEY = $chave; APP_URL = "http://127.0.0.1:$Porta"; LOG_LEVEL = 'warning'
    DB_HOST = '127.0.0.1'; DB_PORT = "$PortaBanco"; DB_DATABASE = 'sistech'; DB_USERNAME = 'sistech'; DB_PASSWORD = $SenhaApp
    SESSION_SECURE_COOKIE = 'false'; SISTECH_ADMIN_PASSWORD = '' })
}
if ($NovoEmissor) {
  $SenhaEm = Senha 28
  Banco "CREATE DATABASE IF NOT EXISTS sistech_emissor CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'sistech_emissor'@'127.0.0.1' IDENTIFIED BY '$SenhaEm'; ALTER USER 'sistech_emissor'@'127.0.0.1' IDENTIFIED BY '$SenhaEm';
    GRANT ALL PRIVILEGES ON sistech_emissor.* TO 'sistech_emissor'@'127.0.0.1'; FLUSH PRIVILEGES;" | Out-Null
  EscreveEnv 'emissor' ([ordered]@{ APP_NAME = '"SISTECH Emissor NFS-e"'; APP_ENV = 'production'; APP_DEBUG = 'false'; APP_KEY = (ChaveApp); APP_URL = "http://127.0.0.1:$PortaEmissor"; LOG_LEVEL = 'warning'
    DB_HOST = '127.0.0.1'; DB_PORT = "$PortaBanco"; DB_DATABASE = 'sistech_emissor'; DB_USERNAME = 'sistech_emissor'; DB_PASSWORD = $SenhaEm
    SESSION_SECURE_COOKIE = 'false'; NFSE_AMBIENTE = 'simulacao'; NFSE_CERTIFICADO = 'storage/app/certificados/teste.pfx'; NFSE_CERTIFICADO_SENHA = 'teste'; NFSE_AUTOMATICO = 'false'
    SISVET_API_URL = "http://127.0.0.1:$Porta/api/v1"; SISVET_URL = "http://127.0.0.1:$Porta"; SISVET_API_CHAVE = ''; EMISSOR_API_CHAVE = '' })
}
$SW = "NT SERVICE\$SvcWeb"

# banco da loja vazio: importa o dump de C:\sistech\importar ou cria do zero
$tabelas = [int](Banco "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='sistech'")
if ($tabelas -eq 0) {
  $dump = Get-ChildItem "$Raiz\importar" -File | Where-Object { $_.Name -match '\.sql(\.gz)?$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($dump) {
    Passo "Importando o banco $($dump.Name)"
    $sql = "$Raiz\tmp\importar.sql"
    if ($dump.Extension -eq '.gz') { Gz2Sql $dump.FullName $sql } else { Copy-Item $dump.FullName $sql }
    $env:MYSQL_PWD = $script:RootSenha
    Exe cmd.exe /c "`"$Raiz\mariadb\bin\mariadb.exe`" -uroot --host=127.0.0.1 -P$PortaBanco --default-character-set=utf8mb4 sistech < `"$sql`"" | Out-Null
    $ok = $script:Codigo; Remove-Item Env:MYSQL_PWD; Remove-Item $sql
    if ($ok) { Falha "a importacao do banco falhou. $($script:Erro)" }
    Move-Item $dump.FullName "$Raiz\backup\importado-$(Get-Date -f yyyyMMdd-HHmmss)-$($dump.Name)"
    Remove-Item "$Raiz\importar\APP_KEY.txt" -ErrorAction SilentlyContinue   # ja esta no .env
  } else { Passo 'Criando as tabelas (banco novo, sem dados)' }
  $NovaSenhaAdmin = Senha 14
}
Artisan 'app' migrate --force
Artisan 'emissor' migrate --force
if ($NovaSenhaAdmin) {
  # admin com senha aleatoria (mostrada uma vez); demais usuarios ficam como vieram
  @'
<?php
require __DIR__.'/../app/vendor/autoload.php';
$app = require __DIR__.'/../app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
App\Models\User::updateOrCreate(['login' => 'admin'], ['name' => 'Administrador', 'email' => 'admin@sistech.local',
    'password' => getenv('SISTECH_SENHA_ADMIN'), 'perfil' => 'admin', 'ativo' => true]);
'@ | Set-Content "$Raiz\tmp\admin.php" -Encoding ASCII
  $env:SISTECH_SENHA_ADMIN = $NovaSenhaAdmin; & "$Raiz\php\php.exe" "$Raiz\tmp\admin.php"; $ok = $LASTEXITCODE
  Remove-Item Env:SISTECH_SENHA_ADMIN; Remove-Item "$Raiz\tmp\admin.php"; if ($ok) { Falha 'nao foi possivel definir a senha do admin.' }
}

# emissor novo: certificado de teste (simulacao), usuario do painel e conexao loja <-> emissor (chaves geradas aqui mesmo)
$SenhaEmissorPainel = $null
if ($NovoEmissor) {
  Passo 'Conectando a loja ao emissor de NFS-e'
  if (-not (Test-Path "$Raiz\emissor\storage\app\certificados\teste.pfx")) { Artisan 'emissor' nfse:certificado-teste }
  $SenhaEmissorPainel = Senha 14
  Artisan 'emissor' nfse:usuario admin@sistech.local --nome=Administrador "--senha=$SenhaEmissorPainel"
  Artisan 'app' emissor:conectar "--emissor=$Raiz\emissor" "--url=http://127.0.0.1:$PortaEmissor"
}
if ($NovaSenhaAdmin -or $SenhaEmissorPainel) {
  @"
SISTECH - acesso inicial ($(Get-Date -f 'dd/MM/yyyy HH:mm'))
Loja:     http://127.0.0.1:$Porta
Usuario:  admin
Senha:    $(if ($NovaSenhaAdmin) { $NovaSenhaAdmin } else { '(a mesma de antes)' })

Painel do emissor de NFS-e (abre sem senha pelo menu Administracao > Painel NF-e / NFS-e): http://127.0.0.1:$PortaEmissor
Usuario:  admin@sistech.local
Senha:    $(if ($SenhaEmissorPainel) { $SenhaEmissorPainel } else { '(a mesma de antes)' })

Troque as senhas no primeiro acesso e apague este arquivo.
"@ | Set-Content "$Raiz\config\ACESSO.txt" -Encoding ASCII
}
foreach ($a in $Apps) { Artisan $a config:cache; Artisan $a route:cache; Artisan $a view:cache }

# --- 8. servico web (Apache + PHP, conta virtual) -----------------------------------------------------------------------
Passo 'Configurando o servidor web'
if (-not (Get-Service $SvcWeb -ErrorAction SilentlyContinue)) {
  Exe "$Raiz\apache\bin\httpd.exe" -k install -n $SvcWeb -f "$Raiz\config\httpd.conf" | Out-Null
  if (-not (Get-Service $SvcWeb -ErrorAction SilentlyContinue)) { Falha 'nao foi possivel criar o servico web.' }
  & sc.exe config $SvcWeb DisplayName= 'SISTECH - Servidor web' start= auto | Out-Null
  & sc.exe description $SvcWeb 'Apache + PHP do SISTECH (loja e emissor de NFS-e)' | Out-Null
}
ContaServico $SvcWeb
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcWeb\Parameters" -Name ConfigArgs -Type MultiString `
  -Value @('-f', "$Raiz\config\httpd.conf", '-E', "$Raiz\logs\web\inicio.log")   # -E: erros de partida do Apache
# o Apache so acha as DLLs do PHP (libcrypto, nghttp2...) com a pasta do PHP no PATH: ambiente proprio do servico, sem mexer no PATH do Windows
New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcWeb" -Name Environment -PropertyType MultiString -Force `
  -Value @("PATH=$Raiz\php;$env:SystemRoot\System32;$env:SystemRoot", "TEMP=$Raiz\tmp\web", "TMP=$Raiz\tmp\web") | Out-Null
foreach ($d in $Apps + @('php', 'apache')) { Icacls "$Raiz\$d" /grant "${SW}:(OI)(CI)RX" }
foreach ($a in $Apps) { foreach ($d in "$a\storage", "$a\bootstrap\cache") { Icacls "$Raiz\$d" /grant "${SW}:(OI)(CI)M" } }
foreach ($d in 'logs\web', 'tmp\web') { Icacls "$Raiz\$d" /grant "${SW}:(OI)(CI)M" }
Icacls "$Raiz\config\httpd.conf" /grant "${SW}:R"
# o Apache resolve o nome real de cada caminho e precisa listar as pastas-pai (so a pasta, sem herdar para o conteudo)
foreach ($d in '', '\config', '\logs', '\tmp') { Icacls "$Raiz$d" /grant "${SW}:(RX)" }
$t = Exe "$Raiz\apache\bin\httpd.exe" -t -f "$Raiz\config\httpd.conf"; if ($script:Codigo) { Falha "configuracao do Apache: $($script:Erro) $t" }
Start-Service $SvcWeb

# firewall: com rede, libera as portas da loja e do emissor e o ping so para a sub-rede local (em qualquer perfil, tambem se a
# rede estiver marcada como Publica); o banco (3307) continua so neste computador
Get-NetFirewallRule -DisplayName 'SISTECH*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Rede) {
  New-NetFirewallRule -DisplayName 'SISTECH' -Direction Inbound -Protocol TCP -LocalPort @($Porta, $PortaEmissor) -Action Allow -Profile Any `
    -RemoteAddress LocalSubnet -Program "$Raiz\apache\bin\httpd.exe" -Description 'SISTECH: loja e emissor de NFS-e para a rede local' | Out-Null
  New-NetFirewallRule -DisplayName 'SISTECH (ping)' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any `
    -RemoteAddress LocalSubnet -Description 'SISTECH: responder ping da rede local' | Out-Null
}

# --- 9. backup diario, atalhos ---------------------------------------------------------------------------------------------
@'
# Backup diario do SISTECH (tarefa agendada "SISTECH - Backup"); guarda os ultimos 30 de cada banco em C:\sistech\backup
$ErrorActionPreference = 'Stop'; $R = 'C:\sistech'
$env:MYSQL_PWD = (Get-Content "$R\config\banco-root.txt" -Raw).Trim()
foreach ($b in 'sistech', 'sistech_emissor') {
  $sql = "$R\tmp\backup-$b.sql"; $gz = "$R\backup\$($b -replace '_', '-')-$(Get-Date -f yyyyMMdd-HHmmss).sql.gz"
  & "$R\mariadb\bin\mariadb-dump.exe" -uroot --host=127.0.0.1 -P3307 --single-transaction --routines --triggers --default-character-set=utf8mb4 "--result-file=$sql" $b
  if ($LASTEXITCODE) { throw "mariadb-dump $b falhou" }
  $i = [IO.File]::OpenRead($sql); $o = [IO.File]::Create($gz); $z = New-Object IO.Compression.GZipStream($o, [IO.Compression.CompressionLevel]::Optimal)
  $i.CopyTo($z); $z.Close(); $o.Close(); $i.Close(); Remove-Item $sql
  Get-ChildItem "$R\backup\$($b -replace '_', '-')-2*.sql.gz" | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item
}
'@ | Set-Content "$Raiz\backup.ps1" -Encoding ASCII
$acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Raiz\backup.ps1`""
Register-ScheduledTask -TaskName 'SISTECH - Backup' -Action $acao -Trigger (New-ScheduledTaskTrigger -Daily -At '12:30') `
  -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit '01:00:00') -Force | Out-Null

"PORTA=$Porta`r`nPORTA_EMISSOR=$PortaEmissor`r`nREDE=$(if ($Rede) { 1 } else { 0 })" | Set-Content "$Raiz\config\opcoes.txt" -Encoding ASCII
$cmdAtual = "irm https://raw.githubusercontent.com/$Repo/main/atualizar.ps1 | iex"
"@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -Command $cmdAtual'`"" |
  Set-Content "$Raiz\ATUALIZAR.cmd" -Encoding ASCII
"@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File $Raiz\backup.ps1'`"" |
  Set-Content "$Raiz\BACKUP-AGORA.cmd" -Encoding ASCII
"[InternetShortcut]`r`nURL=http://127.0.0.1:$Porta/`r`n" | Set-Content "$env:PUBLIC\Desktop\SISTECH.url" -Encoding ASCII

# --- 10. conferencia final ---------------------------------------------------------------------------------------------
foreach ($par in @(@("http://127.0.0.1:$Porta/login", 'a loja'), @("http://127.0.0.1:$PortaEmissor/login", 'o emissor de NFS-e'))) {
  $url, $nome = $par; $ok = $false
  foreach ($i in 1..20) { try { $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10; $ok = $r.StatusCode -eq 200; if ($ok) { break } } catch { Start-Sleep 1 } }
  if (-not $ok) { Falha "$nome nao respondeu em $url (veja $Raiz\logs\web e as pastas storage\logs)" }
}
Remove-Item "$Raiz\tmp\runtime", "$Raiz\tmp\app-nova", "$Raiz\tmp\emissor-nova" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nSISTECH $Versao funcionando em http://127.0.0.1:$Porta (emissor de NFS-e em http://127.0.0.1:$PortaEmissor)" -ForegroundColor Green
if ($Rede) {
  # IP da placa ligada ao roteador (com gateway): deixa de fora as placas virtuais (Hyper-V, WSL, VPN)
  $ips = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | ForEach-Object { $_.IPv4Address.IPAddress })
  $end = @("http://$($env:COMPUTERNAME):$Porta") + ($ips | ForEach-Object { "http://${_}:$Porta" })
  "SISTECH - enderecos para os outros computadores da rede ($(Get-Date -f 'dd/MM/yyyy HH:mm'))`r`n" + ($end -join "`r`n") +
    "`r`n`r`nO painel de NF-e / NFS-e abre pelo menu Administracao (porta $PortaEmissor). Se o endereco pelo IP mudar, reserve um IP fixo para este computador no roteador." | Set-Content "$Raiz\ENDERECOS-REDE.txt" -Encoding ASCII
  Write-Host "Outros computadores da rede acessam por:" -ForegroundColor Green; $end | ForEach-Object { Write-Host "   $_" }
  Write-Host "(lista em $Raiz\ENDERECOS-REDE.txt)"
} else { Remove-Item "$Raiz\ENDERECOS-REDE.txt" -ErrorAction SilentlyContinue }
if ($NovaSenhaAdmin) {
  Write-Host "`nLoja - usuario: admin    senha: $NovaSenhaAdmin" -ForegroundColor Yellow
}
if ($SenhaEmissorPainel) {
  Write-Host "Painel do emissor - usuario: admin@sistech.local    senha: $SenhaEmissorPainel  (pelo menu da loja entra sem senha)" -ForegroundColor Yellow
}
if ($NovaSenhaAdmin -or $SenhaEmissorPainel) { Write-Host "Anote e troque as senhas no primeiro acesso (copia em $Raiz\config\ACESSO.txt, so administradores leem)." }
Write-Host "Servicos: $SvcBanco e $SvcWeb (iniciam com o Windows). Backup diario 12:30 em $Raiz\backup. Atualizar: $Raiz\ATUALIZAR.cmd"
Write-Host "NFS-e em SIMULACAO (sem valor fiscal). Para valer: certificado A1 e NFSE_AMBIENTE em $Raiz\emissor\.env, depois $Raiz\ATUALIZAR.cmd com `$env:SISTECH_FORCAR='1'."
}
