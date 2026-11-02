# SISTECH — instalador para Windows

Sistema de gestão de loja SISTECH rodando no próprio computador (Windows 10/11 64 bits), sem Docker: tudo em `C:\sistech`,
já com o **emissor de NFS-e** conectado (a nota sai de dentro do caixa).
Este repositório só distribui o **instalador** e os **pacotes** de cada versão (aba *Releases*). Nenhum dado de loja fica aqui.

## Instalar (ou atualizar)

Abra o **PowerShell como administrador** (menu Iniciar → *PowerShell* → botão direito → *Executar como administrador*) e cole:

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/instalar.ps1 | iex
```

O instalador:
1. baixa daqui a última versão e confere cada arquivo pelo **SHA-256** publicado na release;
2. instala o Visual C++ da Microsoft se faltar (assinatura conferida);
3. monta PHP 8.4 + Apache 2.4 + MariaDB 11.4 em `C:\sistech` como dois serviços que sobem com o Windows:
   **SISTECH-Banco** e **SISTECH-Web** (loja na porta 8094 e emissor de NFS-e na 8095), cada um na sua conta virtual
   (`NT SERVICE\...`), com acesso só às pastas que usa;
4. **conecta a loja ao emissor sozinho**: gera as chaves de integração dos dois lados, liga a NFS-e automática ao finalizar a venda
   e cria o usuário do painel do emissor (o menu *Administração → Painel NF-e / NFS-e* abre o painel sem pedir outra senha);
5. o site fica **liberado para a rede local**: o firewall abre as duas portas e o ping só para a sub-rede local, e o Apache só atende
   endereços de rede privada (nunca a internet). O banco (porta 3307) atende só este computador. A pasta `C:\sistech` fica restrita a administradores;
6. mostra os endereços para os outros computadores (lista em `C:\sistech\ENDERECOS-REDE.txt`), cria o atalho **SISTECH** na área de trabalho,
   backup diário às 12:30 dos dois bancos em `C:\sistech\backup` (últimos 30) e mostra as senhas iniciais uma vez (cópia em `C:\sistech\config\ACESSO.txt`).

O emissor começa em **simulação** (tudo local, sem valor fiscal). Para homologação/produção: certificado A1 e `NFSE_AMBIENTE` em
`C:\sistech\emissor\.env`, depois `C:\sistech\ATUALIZAR.cmd` com `$env:SISTECH_FORCAR = '1'` (refaz o cache de configuração).

## Atualizar

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/atualizar.ps1 | iex
```

Ou dê duplo clique em `C:\sistech\ATUALIZAR.cmd`. O comando compara a versão instalada com a última publicada e só atualiza quando há uma nova.
Antes, guarda uma cópia dos bancos e mantém os dados, as portas, a opção de rede e a conexão com o emissor. Com `$env:SISTECH_FORCAR = '1'` ele reinstala na mesma versão.

## Levar um banco existente da loja

Antes de instalar, crie `C:\sistech\importar\` e coloque:
- o dump do banco (`*.sql` ou `*.sql.gz`, gerado com `mysqldump`/`mariadb-dump`);
- `APP_KEY.txt` com a linha `base64:...` do `.env` de origem (sem ela os CPF/CNPJ criptografados não abrem).

O dump só é importado quando o banco ainda está vazio; depois vai para `C:\sistech\backup` e a chave é apagada da pasta.

## Opções (antes do comando)

```powershell
$env:SISTECH_PORTA         = '8094'   # porta da loja (o emissor usa a seguinte)
$env:SISTECH_PORTA_EMISSOR = '8095'   # ou uma porta específica para o emissor
$env:SISTECH_REDE          = '0'      # só este computador (padrão '1': liberado para a rede local)
```
As opções ficam gravadas em `C:\sistech\config\opcoes.txt` e valem nas próximas atualizações.

## Recursos

~250 MB de memória com o sistema parado (Apache ~100 MB, MariaDB ~125 MB), ~700 MB em disco mais os bancos.

## Desinstalar

```powershell
irm https://raw.githubusercontent.com/jefersonrte/sistech-instalador/main/desinstalar.ps1 | iex
```
Faz um último backup dos bancos e remove tudo, menos `C:\sistech\backup`.
