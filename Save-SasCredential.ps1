#requires -Version 5.1
<#
.SYNOPSIS
Salva e verifica o SAS no contexto da conta escolhida pelo setup.
.NOTES
Script auxiliar de Setup-Backup.ps1. Recebe pela entrada padrao um JSON
codificado em Base64 com Sid, Arquivo e UrlSas.
#>
$ErrorActionPreference = 'Stop'
$Temporario = $null
try {
    $Entrada = [Console]::In.ReadToEnd()
    $Json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Entrada))
    $Dados = $Json | ConvertFrom-Json
    $SidAtual = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($SidAtual -ne $Dados.Sid) { throw 'Identidade incorreta.' }

    $Segredo = ConvertTo-SecureString $Dados.UrlSas -AsPlainText -Force
    $Credencial = New-Object System.Management.Automation.PSCredential('SAS', $Segredo)
    $Temporario = $Dados.Arquivo + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $Credencial | Export-Clixml -LiteralPath $Temporario
    $Teste = Import-Clixml -LiteralPath $Temporario
    if ($Teste.GetNetworkCredential().Password -cne $Dados.UrlSas) {
        throw 'Falha ao verificar a credencial.'
    }
    Move-Item -LiteralPath $Temporario -Destination $Dados.Arquivo -Force
    exit 0
} catch {
    [Console]::Error.WriteLine('Nao foi possivel salvar o SAS no perfil escolhido.')
    exit 1
} finally {
    if ($Temporario -and (Test-Path -LiteralPath $Temporario)) {
        Remove-Item -LiteralPath $Temporario -Force -ErrorAction SilentlyContinue
    }
}
