#requires -Version 5.1
<#
.SYNOPSIS
Configura a origem, a credencial SAS e a tarefa diaria de backup.
.EXAMPLE
.\Setup-Backup.ps1 -PastaBackup 'D:\app\backups' -Horario '23:00' -Usuario 'DOMINIO\backup'
.NOTES
Execute no Windows Server. -Usuario vincula o SAS e a tarefa a mesma conta.
Use -Atualizar para substituir uma configuracao existente.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PastaBackup,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$Horario,

    [ValidateNotNullOrEmpty()]
    [string]$Usuario = [Security.Principal.WindowsIdentity]::GetCurrent().Name,

    [ValidateNotNullOrEmpty()]
    [string]$NomeTarefa = 'Enviar backup diario para Azure',

    [switch]$Atualizar
)

$ErrorActionPreference = 'Stop'
$CredencialSas = $null
$CredencialWindows = $null
$SenhaWindows = $null
$UrlSas = $null
$ProcessoCredencial = $null
$Payload = $null
$Entrada = $null

try {
    if ($env:OS -ne 'Windows_NT') { throw 'Execute o setup no Windows Server.' }

    # Valida os arquivos e a origem antes de configurar.
    $ScriptBackup = Join-Path $PSScriptRoot 'Start-Backup.ps1'
    $ScriptCredencial = Join-Path $PSScriptRoot 'Save-SasCredential.ps1'
    $AzCopy = Join-Path $PSScriptRoot 'azcopy.exe'
    $ArquivoConfig = Join-Path $PSScriptRoot 'backup-config.json'
    $ArquivoCredencial = Join-Path $PSScriptRoot 'azure-sas.xml'

    foreach ($Caminho in @($ScriptBackup, $ScriptCredencial, $AzCopy)) {
        if (-not (Test-Path -LiteralPath $Caminho -PathType Leaf)) {
            throw "Arquivo obrigatorio nao encontrado: $Caminho"
        }
    }

    if (-not [IO.Path]::IsPathRooted($PastaBackup) -or
        -not (Test-Path -LiteralPath $PastaBackup -PathType Container)) {
        throw 'Informe o caminho absoluto de uma pasta de backup existente.'
    }
    $PastaBackup = (Resolve-Path -LiteralPath $PastaBackup).ProviderPath

    & $AzCopy --version
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel executar o AzCopy.' }

    Import-Module ScheduledTasks -ErrorAction Stop
    $TarefaExistente = Get-ScheduledTask | Where-Object {
        $_.TaskPath -eq '\' -and $_.TaskName -eq $NomeTarefa
    }
    if (-not $Atualizar -and ($TarefaExistente -or
        (Test-Path -LiteralPath $ArquivoConfig) -or
        (Test-Path -LiteralPath $ArquivoCredencial))) {
        throw 'Configuracao ou tarefa existente. Use -Atualizar para substituir.'
    }
    if ($TarefaExistente -and $TarefaExistente.State -eq 'Running') {
        throw 'A tarefa esta em execucao. Aguarde sua conclusao antes de atualizar.'
    }

    # Solicita a senha da conta escolhida para a tarefa.
    $Identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $ContaTarefa = New-Object System.Security.Principal.NTAccount($Usuario)
    $SidTarefa = $ContaTarefa.Translate([Security.Principal.SecurityIdentifier])
    $Usuario = $SidTarefa.Translate([Security.Principal.NTAccount]).Value
    $MesmaConta = $SidTarefa.Value -eq $Identidade.User.Value
    Write-Host "Conta da tarefa: $Usuario"
    $SenhaSegura = Read-Host 'Senha Windows dessa conta (nao e o PIN)' -AsSecureString
    if ($SenhaSegura.Length -eq 0) { throw 'A senha Windows e obrigatoria.' }
    $CredencialWindows = New-Object System.Management.Automation.PSCredential($Usuario, $SenhaSegura)

    # O SAS deve ser protegido pela conta que executara o backup.
    $Sas = Read-Host 'URL HTTPS completa do container com SAS' -AsSecureString
    $CredencialSas = New-Object System.Management.Automation.PSCredential('SAS', $Sas)
    $UrlSas = $CredencialSas.GetNetworkCredential().Password.Trim()
    $UriSas = $null
    if (-not [Uri]::TryCreate($UrlSas, [UriKind]::Absolute, [ref]$UriSas) -or
        $UriSas.Scheme -ne 'https' -or [string]::IsNullOrEmpty($UriSas.Query) -or
        $UriSas.AbsolutePath.Trim('/') -notmatch '^[^/]+$' -or
        -not [string]::IsNullOrEmpty($UriSas.Fragment)) {
        throw 'Informe uma URL HTTPS de container com SAS, sem nome de arquivo.'
    }

    # Agenda diariamente no horario local do servidor.
    $PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Acao = New-ScheduledTaskAction -Execute $PowerShell `
        -Argument ('-NoProfile -NonInteractive -File "{0}"' -f $ScriptBackup) `
        -WorkingDirectory $PSScriptRoot
    $Hora = [datetime]::ParseExact($Horario, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $Disparador = New-ScheduledTaskTrigger -Daily -At $Hora
    $Opcoes = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 15) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)

    # Salva a origem e a credencial protegida pelo Windows.
    New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'Logs') -Force | Out-Null
    @{ PastaBackup = $PastaBackup; Usuario = $Usuario } | ConvertTo-Json |
        Set-Content -LiteralPath $ArquivoConfig -Encoding UTF8
    if ($MesmaConta) {
        $CredencialSas | Export-Clixml -LiteralPath $ArquivoCredencial
    } else {
        # Cria e verifica o XML no perfil do usuario escolhido.
        $Inicio = New-Object System.Diagnostics.ProcessStartInfo
        $Inicio.FileName = $PowerShell
        $Inicio.Arguments = '-NoProfile -NonInteractive -File "{0}"' -f $ScriptCredencial
        $Inicio.UseShellExecute = $false
        $Inicio.LoadUserProfile = $true
        $Inicio.RedirectStandardInput = $true
        $Inicio.WorkingDirectory = $PSScriptRoot
        $Dominio, $Login = $Usuario -split '\\', 2
        $Inicio.Domain = $Dominio
        $Inicio.UserName = $Login
        $Inicio.Password = $SenhaSegura

        # Transmite o SAS pela entrada do processo, sem arquivo ou argumento.
        $Payload = @{
            Sid = $SidTarefa.Value
            Arquivo = $ArquivoCredencial
            UrlSas = $UrlSas
        } | ConvertTo-Json -Compress
        $Entrada = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Payload))
        $ProcessoCredencial = [Diagnostics.Process]::Start($Inicio)
        $ProcessoCredencial.StandardInput.Write($Entrada)
        $ProcessoCredencial.StandardInput.Close()
        $ProcessoCredencial.WaitForExit()
        if ($ProcessoCredencial.ExitCode -ne 0) {
            throw "Falha ao vincular o SAS a $Usuario. Verifique o logon e a permissao de escrita na pasta."
        }
    }

    # O Agendador exige a senha em memoria para logon sem sessao aberta.
    $SenhaWindows = $CredencialWindows.GetNetworkCredential().Password
    Register-ScheduledTask -TaskName $NomeTarefa -TaskPath '\' `
        -Action $Acao -Trigger $Disparador -Settings $Opcoes `
        -User $Usuario -Password $SenhaWindows -RunLevel Limited `
        -Description 'Envia o RAR mais recente para Azure Blob Storage.' `
        -Force:$Atualizar | Out-Null

    Write-Host "Setup concluido. Tarefa: $NomeTarefa; usuario: $Usuario; horario: $Horario."
    Write-Host "SAS vinculado a $Usuario. Teste o envio com essa conta."
} catch {
    [Console]::Error.WriteLine("Setup nao concluido: $($_.Exception.Message)")
    [Console]::Error.WriteLine('Se arquivos ja foram gravados, corrija a falha e execute com -Atualizar.')
    exit 1
} finally {
    if ($ProcessoCredencial) { $ProcessoCredencial.Dispose() }
    $Payload = $null
    $Entrada = $null
    $Inicio = $null
    $SenhaWindows = $null
    $SenhaSegura = $null
    $CredencialWindows = $null
    $CredencialSas = $null
    $Sas = $null
    $UrlSas = $null
    $UriSas = $null
}
