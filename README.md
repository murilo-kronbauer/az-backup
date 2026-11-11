# az-backup

Envio do backup diário de um Windows Server **fora da Azure** para Azure Blob Storage, usando PowerShell, AzCopy e Agendador de Tarefas.

## Cenário e decisões

- Backup diário em formato **RAR**.
- Enviar somente o RAR mais recente da pasta, pela última modificação (`LastWriteTimeUtc`). Não pesquisar subpastas.
- Origem informada: `/app/backups`. No Windows, configurar o caminho absoluto com a unidade real; `X:\app\backups` é um placeholder.
- Pasta da automação: **`C:\AzureBackup`**.
- Agendar após a conclusão do backup pela aplicação. O script não confirma se o arquivo está completo; não há marcador de conclusão nem espera por estabilidade.
- Autenticação por URL SAS do container, guardada com proteção do Windows.
- Os arquivos locais são preservados.

Definir na implantação: unidade real da origem, horário, conta Windows de execução, assinatura, região, redundância, nomes dos recursos, IP de saída e validade do SAS. Este projeto não contém credenciais nem provisiona recursos Azure.

## Arquivos

| Arquivo | Função |
| --- | --- |
| `Start-Backup.ps1` | Seleciona e envia o RAR mais recente. |
| `Setup-Backup.ps1` | Configura a origem, salva o SAS e registra a tarefa diária. |
| `Save-SasCredential.ps1` | Auxiliar do setup que salva e verifica o SAS na conta escolhida. |
| `Install-AzCopy.ps1` | Baixa o AzCopy v10 para Windows x64 e adiciona sua pasta ao PATH do sistema. |
| `backup-config.json` | Origem e usuário informados ao setup; arquivo local ignorado pelo Git. |
| `azure-sas.xml` | Credencial SAS protegida para o usuário da tarefa; ignorada pelo Git. |
| `.gitignore` | Ignora credenciais, configuração local, logs e backups no Git. |

## 1. Criar a conta de armazenamento e o container

No [Portal Azure](https://portal.azure.com):

1. Crie ou selecione um Resource Group.
2. Crie uma Storage Account **Standard**, de uso geral v2 (**StorageV2**), com camada **Hot** para esta configuração inicial.
3. Escolha região e redundância conforme a infraestrutura. LRS, ZRS e GRS oferecem proteções e custos diferentes.
4. Exija HTTPS e desabilite acesso anônimo a blobs.
5. Mantenha **Allow storage account key access** habilitado para o service SAS deste procedimento.
6. Em **Data storage → Containers**, crie `backups`, com acesso privado.

URL do container sem credencial:

```text
https://NOME-DA-CONTA.blob.core.windows.net/backups
```

### Conectividade

Para acesso pela internet, em **Networking**, habilite o endpoint público somente para redes/endereços selecionados e autorize o IP público de saída do Windows Server. O servidor precisa de saída HTTPS/443 para o armazenamento. Atualize a regra caso o IP público mude.

Acesso privado exige VPN/ExpressRoute, Private Endpoint, roteamento e DNS compatíveis; essa conectividade não é criada por este projeto.

## 2. Gerar a URL SAS

No container, abra **Generate SAS** e configure:

| Campo | Valor |
| --- | --- |
| Signing method | Account key |
| Signing key | Uma das chaves disponíveis |
| Stored access policy | None |
| Permissions | Read, Create e Write; sem Delete |
| Allowed protocols | HTTPS only |
| Start | Horário anterior ao teste |
| Expiry | Vencimento escolhido para a credencial |

Gere e copie a **Blob SAS URL completa**, com o endereço do container e o token após `?`. Não use uma URL SAS de um único arquivo.

```text
https://NOME-DA-CONTA.blob.core.windows.net/backups?TOKEN-SAS
```

A URL é uma credencial: quem a possui pode exercer as permissões concedidas durante a validade. Não a coloque no Git, em tickets ou neste README. Renove-o antes do vencimento.

## 3. Preparar o Windows Server

Requisitos: Windows Server com Windows PowerShell 5.1 e módulo `ScheduledTasks`, AzCopy v10 e conta Windows com leitura da origem, alteração em `C:\AzureBackup`, acesso à rede e direito de executar tarefas em lote. O instalador baixa o binário para Windows x64; o executável não é distribuído neste projeto. O agendamento usa `powershell.exe` do Windows, mesmo quando o setup é iniciado por outro PowerShell.

### Instalar ou atualizar o AzCopy e configurar o PATH

Copie `Install-AzCopy.ps1` para o Windows Server e execute no **PowerShell como Administrador**, a partir da pasta onde salvou o instalador:

```powershell
.\Install-AzCopy.ps1 -Destino 'C:\AzureBackup'
azcopy --version
```

O instalador baixa o ZIP oficial da Microsoft, extrai `azcopy.exe`, substitui o executável no destino e adiciona essa pasta ao PATH do sistema, sem duplicar a mesma entrada. Também atualiza o PATH da sessão atual e remove os arquivos temporários. Reabra outros terminais já abertos para usar o PATH atualizado.

Use `-Destino 'C:\AzureBackup'` para manter o executável junto de `Setup-Backup.ps1` e `Start-Backup.ps1`, como os scripts exigem. Se usar outra pasta de automação, informe essa mesma pasta no parâmetro. Sem `-Destino`, o instalador usa `C:\Program Files\AzCopy`; nesse caso, copie também o executável para a pasta da automação. Adicionar ao PATH não altera o caminho usado pelos scripts de backup.

A instalação é uma etapa separada: execute-a antes do setup para disponibilizar `azcopy.exe` na pasta da automação. Ela requer conexão HTTPS ao download da Microsoft e não configura credenciais nem agenda backups.

### Setup automático

Após criar o container e gerar o SAS, copie `Setup-Backup.ps1`, `Save-SasCredential.ps1` e `Start-Backup.ps1` para `C:\AzureBackup`, onde o AzCopy foi instalado na etapa anterior. Execute no próprio Windows Server, com permissão para registrar tarefas:

```powershell
Set-Location 'C:\AzureBackup'
.\Setup-Backup.ps1 -PastaBackup 'D:\app\backups' -Horario '23:00' -Usuario 'DOMINIO\backup'
```

Substitua a unidade e escolha um horário posterior à conclusão do backup. O parâmetro `-Usuario` define a conta vinculada ao SAS e à tarefa (por exemplo, `DOMINIO\backup` ou `SERVIDOR\backup`); se omitido, usa a conta atual. O setup solicita a senha Windows dessa conta e a URL SAS sem exibi-las. Salva a origem em `backup-config.json`, protege o SAS em `azure-sas.xml` e registra a tarefa `Enviar backup diario para Azure`, para executar mesmo sem sessão aberta.

Se o setup for executado por outra conta, ele inicia `Save-SasCredential.ps1` em um processo com o usuário escolhido, carrega seu perfil e gera e verifica o XML nesse contexto. Assim, a proteção DPAPI vincula a credencial ao mesmo usuário da tarefa, sem etapa manual adicional. Essa conta precisa poder iniciar sessão no servidor e gravar na pasta da automação, além de ler os backups e executar tarefas em lote. O SAS é transmitido pela entrada do processo, sem gravá-lo em texto aberto em arquivos ou argumentos.

Parâmetros do setup:

| Parâmetro | Comportamento |
| --- | --- |
| `-PastaBackup` | Obrigatório; caminho absoluto de uma pasta existente. |
| `-Horario` | Obrigatório; horário diário no formato `HH:mm`, de `00:00` a `23:59`. |
| `-Usuario` | Conta vinculada ao SAS e à tarefa; padrão: usuário que executa o setup. |
| `-NomeTarefa` | Nome da tarefa na raiz do Agendador; padrão: `Enviar backup diario para Azure`. |
| `-Atualizar` | Permite substituir a configuração, a credencial e a tarefa de mesmo nome. |

O agendamento usa o horário local do servidor, executa assim que possível após um horário perdido, tenta novamente até três vezes em intervalos de 15 minutos, impede execuções simultâneas e limita cada execução a 12 horas. Ajuste esse limite no Agendador conforme o tempo de envio.

Para reconfigurar ou renovar o SAS, repita o comando completo com `-Atualizar`. O setup solicita novamente a senha Windows e a URL SAS e grava os valores informados; não reutiliza automaticamente o usuário ou o nome da tarefa anterior. Se usou `-NomeTarefa`, informe o mesmo nome na atualização:

```powershell
.\Setup-Backup.ps1 -PastaBackup 'D:\app\backups' -Horario '23:00' -Usuario 'DOMINIO\backup' -NomeTarefa 'Enviar backup diario para Azure' -Atualizar
```

Sem `-Atualizar`, o setup recusa configurações, credenciais ou tarefas de mesmo nome já existentes. Uma tarefa em execução impede a atualização. Alterar `-NomeTarefa` cria outra tarefa e mantém a anterior; ambas usarão os mesmos arquivos de configuração se estiverem nesta pasta. Use uma pasta separada para cada configuração independente.

Se ocorrer uma falha após a gravação dos arquivos, eles podem permanecer alterados; o setup não desfaz mudanças anteriores. Corrija a causa e repita com `-Atualizar`. Esse parâmetro armazena o SAS fornecido; não gera nem renova tokens na Azure.

O setup não envia o backup nem valida o acesso à Azure. Depois de concluí-lo, siga a seção **5. Testar o envio e a recuperação**. Quem utilizou o setup pode pular as seções **4** e **6**, que descrevem a configuração manual. Restrinja as permissões NTFS da pasta aos administradores e à conta de execução; o setup não altera essas permissões.

### Preparação manual

```powershell
New-Item -ItemType Directory -Path 'C:\AzureBackup' -Force
```

Copie `Start-Backup.ps1` para `C:\AzureBackup` e instale o AzCopy nessa mesma pasta conforme a etapa anterior. Como alternativa, obtenha-o pelo [download oficial do AzCopy](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10) e coloque `azcopy.exe` junto do script. O executável é ignorado pelo Git.

Confira a versão no Windows Server:

```powershell
& 'C:\AzureBackup\azcopy.exe' --version
```

Na configuração manual, edite o início do script, trocando `X:` pela unidade real. Se existir `backup-config.json`, a origem salva pelo setup terá prioridade:

```powershell
$PastaBackup = 'X:\app\backups'
```

Os demais caminhos são relativos à pasta do script (`$PSScriptRoot`):

```text
C:\AzureBackup\
    azcopy.exe          (instalado separadamente)
    azure-sas.xml
    backup-config.json    (gerado pelo setup)
    Install-AzCopy.ps1    (instalador opcional)
    Setup-Backup.ps1
    Save-SasCredential.ps1
    Start-Backup.ps1
    Logs\
```

Restrinja as permissões NTFS aos administradores e à conta de execução. Siga a política de execução e assinatura de scripts da organização.

## 4. Guardar a credencial SAS manualmente

Esta etapa já é realizada pelo setup automático.

Execute no próprio Windows Server, **com a mesma conta que executará a tarefa agendada**:

```powershell
$Sas = Read-Host 'Cole a URL completa do container com SAS' -AsSecureString
$Credencial = New-Object System.Management.Automation.PSCredential(
    'SAS',
    $Sas
)
$Credencial | Export-Clixml 'C:\AzureBackup\azure-sas.xml'
```

`SAS` é apenas um identificador local, não um usuário Azure. O campo de senha contém a URL completa. No Windows, `Export-Clixml` protege esse campo com DPAPI: somente a mesma conta, no mesmo computador, pode descriptografá-lo.

O script importa o XML, recupera a URL em memória e monta o destino para o AzCopy. O XML não emite nem renova o SAS; apenas armazena a credencial gerada na Azure.

Para renovar, gere outra URL e repita os comandos. Ao trocar de servidor ou conta de execução, prepare novamente o XML no contexto correto.

## 5. Testar o envio e a recuperação

Com a conta da tarefa:

```powershell
& 'C:\AzureBackup\Start-Backup.ps1'
$LASTEXITCODE
```

- `0`: AzCopy concluiu sem erro; o objeto foi enviado ou já existia no destino.
- `1`: houve erro; consulte `C:\AzureBackup\Logs` e a saída de erro. Falhas na leitura da configuração ou na preparação da pasta de logs podem ocorrer antes da criação do log diário.

Confira o RAR e seu tamanho no container. Baixe o arquivo, teste sua integridade com ferramenta compatível e valide a restauração na aplicação.

O nome remoto combina data de modificação em UTC e nome original. Isso preserva histórico se o sistema reutiliza o nome, desde que a data mude. Para o mesmo nome e data, o destino é o mesmo e `--overwrite=false` pula o objeto existente. O script confere o tamanho das transferências realizadas e grava a propriedade MD5; isso não substitui o teste de restauração.

## 6. Configurar o Agendador de Tarefas manualmente

O setup já registra a tarefa. Se o utilizou, abra a tarefa existente apenas para conferir ou testar. Para a configuração manual, abra `taskschd.msc` e selecione **Criar Tarefa**.

### Geral

- Nome: `Enviar backup diario para Azure` (mesmo padrão do setup).
- Usuário: a mesma conta usada para gerar `azure-sas.xml`.
- Executar estando o usuário conectado ou não.
- Privilégios elevados não são necessários se as permissões estiverem corretas.
- Use uma configuração de logon que permita acesso à rede.

### Disparador

Diariamente, no horário definido como posterior à conclusão do backup.

### Ação

Programa:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

Argumentos:

```text
-NoProfile -NonInteractive -File "C:\AzureBackup\Start-Backup.ps1"
```

Iniciar em:

```text
C:\AzureBackup
```

### Configurações e teste

- Executar assim que possível após um horário perdido.
- Configurar até três novas tentativas em intervalos de 15 minutos, como no setup.
- Não iniciar nova instância se a tarefa já estiver executando.
- Definir o limite de duração conforme o tempo medido do envio; o setup usa 12 horas.

Salve, informe a senha da conta se solicitada e execute manualmente. Confira **Último Resultado = `0x0`**, o log e o objeto na Azure.

## Operação e limites

- Somente o arquivo mais recente é enviado. Se um envio falhar e um RAR novo surgir, a próxima execução não recupera automaticamente o anterior.
- O script não confirma se o backup é do dia. Pode selecionar novamente um arquivo antigo e retornar sucesso por ele já existir no destino.
- O horário deve assegurar que o arquivo está completo; não há espera pela aplicação.
- O fluxo trata um único RAR. Backups divididos em volumes exigem adaptação.
- Não há limpeza local, monitoramento independente ou alerta implementado.
- Acompanhe logs e resultados, renove o SAS, faça testes de restauração e defina limpeza periódica dos logs e planos do AzCopy.
- Não há exclusão automática de objetos na Azure neste projeto. O armazenamento cresce conforme novos backups são enviados.

## Validação

O script usa o filtro `*.rar`. O setup e o envio precisam ser homologados no Windows Server com o AzCopy, o SAS e a rede reais; não foram executados neste ambiente Linux. A criação deste repositório não comprova uma transferência para a Azure.

## Referências

- [Processos com credenciais e perfil de usuário](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo)
- [Configurações de tarefas agendadas](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset?view=windowsserver2025-ps)
- [Instalação do AzCopy](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10)
- [Containers e geração de SAS](https://learn.microsoft.com/en-us/azure/storage/blobs/blob-containers-portal)
- [Opções de azcopy copy](https://github.com/Azure/azure-storage-azcopy/wiki/azcopy_copy)
- [Export-Clixml e proteção de credenciais](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml?view=powershell-5.1)
