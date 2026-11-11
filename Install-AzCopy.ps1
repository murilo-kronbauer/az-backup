#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Baixa o AzCopy v10 para Windows x64 e adiciona a pasta ao PATH do sistema.
.EXAMPLE
.\Install-AzCopy.ps1 -Destino 'C:\AzureBackup'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Destino = "$env:ProgramFiles\AzCopy"
)

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Este instalador requer Windows x64.'
}
if (-not [IO.Path]::IsPathRooted($Destino) -or $Destino.Contains(';')) {
    throw 'Informe um caminho absoluto sem ponto e virgula em -Destino.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$TempDir = Join-Path $env:TEMP ('azcopy-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' `
        -OutFile "$TempDir\azcopy.zip" -UseBasicParsing
    Expand-Archive -Path "$TempDir\azcopy.zip" -DestinationPath "$TempDir\extraido"

    $Exe = Get-ChildItem "$TempDir\extraido" -Filter azcopy.exe -Recurse -File |
        Select-Object -First 1
    if (-not $Exe) { throw 'azcopy.exe nao encontrado no download.' }

    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
    $Destino = (Resolve-Path -LiteralPath $Destino).ProviderPath
    $AzCopy = Join-Path $Destino 'azcopy.exe'
    Copy-Item -LiteralPath $Exe.FullName -Destination $AzCopy -Force

    & $AzCopy --version
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao verificar a versao do AzCopy.' }

    $PathSistema = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($PathSistema -split ';') -notcontains $Destino) {
        $NovoPath = if ([string]::IsNullOrEmpty($PathSistema)) {
            $Destino
        } else {
            $PathSistema.TrimEnd(';') + ';' + $Destino
        }
        [Environment]::SetEnvironmentVariable('Path', $NovoPath, 'Machine')
    }

    # Disponibiliza tambem nesta sessao do PowerShell.
    $env:Path = "$Destino;$env:Path"
    Write-Host "AzCopy instalado em $AzCopy e pasta adicionada ao PATH do sistema."
    Write-Host 'Reabra outros terminais ja abertos para usar o PATH atualizado.'
}
finally {
    Remove-Item -LiteralPath $TempDir -Recurse -Force
}
