#requires -Version 5.1
<#
.SYNOPSIS
Envia o RAR mais recente para Azure Blob Storage via AzCopy.
.EXAMPLE
& 'C:\AzureBackup\Start-Backup.ps1'
.NOTES
Execute apos concluir o backup. Requer azcopy.exe e azure-sas.xml locais.
Crie a credencial com a mesma conta e no mesmo Windows Server da execucao.
Saida: 0 = enviado ou ja existente; 1 = erro.
#>

# Troque X: pela unidade real.
$PastaBackup = 'X:\app\backups'

# Caminhos relativos ao script.
$AzCopy = Join-Path $PSScriptRoot 'azcopy.exe'
$ArquivoCredencial = Join-Path $PSScriptRoot 'azure-sas.xml'
$PastaLogs = Join-Path $PSScriptRoot 'Logs'

$ErrorActionPreference = 'Stop'
$CodigoSaida = 1
$Log = $null

try {
    # Usa a origem salva pelo setup, quando disponivel.
    $ArquivoConfig = Join-Path $PSScriptRoot 'backup-config.json'
    if (Test-Path -LiteralPath $ArquivoConfig -PathType Leaf) {
        $Config = Get-Content -LiteralPath $ArquivoConfig -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($Config.PastaBackup)) {
            throw 'PastaBackup ausente em backup-config.json.'
        }
        $PastaBackup = $Config.PastaBackup
    }

    # Prepara o log diario.
    New-Item -ItemType Directory -Path $PastaLogs -Force | Out-Null
    $Log = Join-Path $PastaLogs ('envio-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

    # Valida a pasta de origem.
    if (-not (Test-Path -LiteralPath $PastaBackup -PathType Container)) {
        throw 'Configure uma pasta de backup existente, com a unidade correta.'
    }

    # Verifica se azcopy.exe existe na pasta do script.
    if (-not (Test-Path -LiteralPath $AzCopy -PathType Leaf)) {
        throw 'azcopy.exe nao encontrado na pasta do script.'
    }

    # Seleciona o RAR mais recente, sem subpastas.
    $Arquivo = Get-ChildItem -LiteralPath $PastaBackup -Filter '*.rar' -File |
        Sort-Object -Property LastWriteTimeUtc, Name -Descending |
        Select-Object -First 1
    if ($null -eq $Arquivo) { throw 'Nenhum arquivo RAR encontrado na pasta.' }

    # Carrega a credencial SAS.
    $Credencial = Import-Clixml -LiteralPath $ArquivoCredencial
    $UrlSas = $Credencial.GetNetworkCredential().Password.Trim()

    # Valida o formato da URL SAS.
    $Separador = $UrlSas.IndexOf('?')
    if ($Separador -lt 0 -or -not $UrlSas.StartsWith('https://')) {
        throw 'A credencial deve conter a URL HTTPS completa do container com SAS.'
    }

    $Container = $UrlSas.Substring(0, $Separador).TrimEnd('/')
    $Token = $UrlSas.Substring($Separador + 1)

    # Combina data UTC e nome original no destino.
    $NomeRemoto = '{0}-{1}' -f $Arquivo.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssfffffffZ'), $Arquivo.Name
    $Destino = $Container + '/' + [Uri]::EscapeDataString($NomeRemoto) + '?' + $Token

    # Configura os logs e planos do AzCopy.
    $env:AZCOPY_LOG_LOCATION = $PastaLogs
    $env:AZCOPY_JOB_PLAN_LOCATION = $PastaLogs

    # Envia sem sobrescrever, verificando tamanho e gravando MD5.
    Add-Content -LiteralPath $Log -Value "$(Get-Date -Format o) Enviando $($Arquivo.FullName)"
    & $AzCopy copy $Arquivo.FullName $Destino '--from-to=LocalBlob' `
        '--overwrite=false' '--check-length=true' '--put-md5=true' `
        '--output-level=essential' 2>&1 |
        Out-File -LiteralPath $Log -Append -Encoding UTF8

    # Confere o resultado do AzCopy.
    $Resultado = $LASTEXITCODE
    if ($Resultado -ne 0) { throw "AzCopy terminou com codigo $Resultado. Consulte os logs." }

    Add-Content -LiteralPath $Log -Value "$(Get-Date -Format o) Concluido: enviado ou ja existente no destino."
    $CodigoSaida = 0
} catch {
    # Registra a falha.
    $Mensagem = "$(Get-Date -Format o) ERRO: $($_.Exception.Message)"
    if ($Log) { Add-Content -LiteralPath $Log -Value $Mensagem }
    [Console]::Error.WriteLine($Mensagem)
} finally {
    # Libera referencias a credencial.
    $Destino = $null
    $UrlSas = $null
    $Token = $null
    $Credencial = $null
}

exit $CodigoSaida
