# Descarrega o zip da última release, gera o MSIX assinado e abre-o.
# Pacotes em falta (Trust My Msix, Windows SDK, App Installer) abrem uma janela
# do PowerShell que os instala com o winget.

$ErrorActionPreference = "Stop"
# O "Executar com o PowerShell" fecha a janela assim que o script termina.
# Sem isto, o erro da assinatura desaparece.
trap {
    Write-Host ""
    Write-Host "ERRO: $_" -ForegroundColor Red
    Read-Host "Enter para fechar"
    break
}

$root = $PSScriptRoot
$repo = "brunorochaipca/hyper-v_creator"
$empacotar = Join-Path $root "packaging\empacotar.ps1"
$releaseDir = Join-Path $root "packaging\release"
$msix = Join-Path $root "packaging\CriarVmWindows.msix"

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
    $tmmDir = "C:\Program Files\Chill-Astro\Trust My Msix!"
    if (Test-Path -LiteralPath $tmmDir) { $env:Path = "$tmmDir;$env:Path" }
}

function Find-MakeAppx {
    $nugetRoots = @()
    if ($env:NUGET_PACKAGES) { $nugetRoots += $env:NUGET_PACKAGES }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $locals = dotnet nuget locals global-packages -l 2>$null
        if ($locals -match "global-packages:\s*(.+)") { $nugetRoots += $Matches[1].Trim() }
    }
    $nugetRoots += Join-Path $env:USERPROFILE ".nuget\packages"
    foreach ($nugetRoot in ($nugetRoots | Select-Object -Unique)) {
        $package = Join-Path $nugetRoot "microsoft.windows.sdk.buildtools"
        if (Test-Path -LiteralPath $package) {
            $found = Get-ChildItem -Path $package -Recurse -Filter "makeappx.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\x64\\" } |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kits) {
        $found = Get-ChildItem -Path $kits -Recurse -Filter "makeappx.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\x64\\" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Find-Tmm {
    $command = Get-Command tmm -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\tmm.exe"),
        "C:\Program Files\Chill-Astro\Trust My Msix!\tmm.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-MissingPackages {
    $missing = @()
    if (-not (Find-Tmm)) {
        $missing += [pscustomobject]@{ Id = "Chill-Astro.TMM"; Nome = "Trust My Msix" }
    }
    if (-not (Find-MakeAppx)) {
        $missing += [pscustomobject]@{ Id = "Microsoft.WindowsSDK.10.0.26100"; Nome = "Windows SDK (makeappx e signtool)" }
    }
    if (-not (Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue)) {
        $missing += [pscustomobject]@{ Id = "Microsoft.AppInstaller"; Nome = "App Installer" }
    }
    return $missing
}

function Install-MissingPackages {
    param($Packages)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "O winget não está instalado. Instala o App Installer e volta a correr .\instalar.ps1."
    }

    $lines = @(
        '$ErrorActionPreference = "Continue"',
        'Write-Host "A instalar os pacotes em falta para o Criar VM Windows."',
        'Write-Host ""'
    )
    foreach ($package in $Packages) {
        $lines += "Write-Host '--- $($package.Nome) ---'"
        $lines += "winget install --id $($package.Id) -e --accept-package-agreements --accept-source-agreements --disable-interactivity"
        $lines += 'if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { Write-Host "A instalação de ' + $package.Id + ' falhou (código $LASTEXITCODE)." }'
        $lines += 'Write-Host ""'
    }
    $lines += 'Write-Host "Podes fechar esta janela."'
    $lines += 'Read-Host "Enter"'

    $file = Join-Path $env:TEMP "CriarVmWindows-pacotes.ps1"
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($file, ($lines -join "`r`n"), $utf8)

    Write-Host "Faltam pacotes. A abrir o PowerShell para os instalar:"
    foreach ($package in $Packages) { Write-Host "  $($package.Nome)" }

    try {
        $window = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -Wait -PassThru `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $file)
    } catch {
        throw "Não foi possível abrir o PowerShell como administrador para instalar os pacotes."
    }
    if ($null -ne $window.ExitCode -and $window.ExitCode -ne 0) {
        throw "A instalação dos pacotes no PowerShell terminou com o código $($window.ExitCode)."
    }
}

try {
    $remote = git -C $root remote get-url origin 2>$null
    if ($remote -match "github\.com[:/]([^/]+)/([^/.\s]+)") {
        $repo = "$($Matches[1])/$($Matches[2])"
    }
} catch {
    # Sem git, usa o repositório de origem.
}

# Quem descarrega só este script não traz o packaging\. Vai buscá-lo ao mesmo repositório.
$packDir = Join-Path $root "packaging"
foreach ($name in @("empacotar.ps1", "AppxManifest.xml")) {
    $destino = Join-Path $packDir $name
    if (Test-Path -LiteralPath $destino) { continue }
    if (-not (Test-Path -LiteralPath $packDir)) {
        New-Item -ItemType Directory -Path $packDir | Out-Null
    }
    $url = "https://raw.githubusercontent.com/$repo/main/packaging/$name"
    Write-Host "A obter packaging\$name..."
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $url -OutFile $destino -Headers @{ "User-Agent" = "CriarVmWindows-instalador" }
    $ProgressPreference = "Continue"
}

Refresh-Path
$missing = @(Get-MissingPackages)
if ($missing.Count -gt 0) {
    Install-MissingPackages $missing
    Refresh-Path
    $missing = @(Get-MissingPackages)
    if ($missing.Count -gt 0) {
        $nomes = ($missing | ForEach-Object { $_.Nome }) -join ", "
        throw "Ainda faltam pacotes: $nomes"
    }
}

$headers = @{
    "User-Agent" = "CriarVmWindows-instalador"
    "Accept"     = "application/vnd.github+json"
}
Write-Host "A procurar a última release de $repo..."
$release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/releases/latest"
$asset = @($release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1)
if ($asset.Count -eq 0) {
    throw "A release $($release.tag_name) não tem um ficheiro .zip."
}

$zip = Join-Path $releaseDir $asset[0].name
if (Test-Path -LiteralPath $releaseDir) { Remove-Item -LiteralPath $releaseDir -Recurse -Force }
New-Item -ItemType Directory -Path $releaseDir | Out-Null

Write-Host "A descarregar $($asset[0].name) ($($release.tag_name))..."
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $zip -Headers @{ "User-Agent" = "CriarVmWindows-instalador" }
$ProgressPreference = "Continue"
Expand-Archive -LiteralPath $zip -DestinationPath $releaseDir -Force

$exe = Get-ChildItem -LiteralPath $releaseDir -Recurse -Filter "CriarVmWindows.exe" | Select-Object -First 1
if (-not $exe) { throw "O zip da release não contém CriarVmWindows.exe." }

Write-Host "A gerar o instalador certificado..."
& $empacotar -Conteudo $exe.DirectoryName -Versao $release.tag_name -Confiar
if ($LASTEXITCODE -ne 0) { throw "A geração do MSIX falhou com o código $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $msix)) { throw "Não encontrei o MSIX em $msix." }

Write-Host "A abrir $msix"
Start-Process -FilePath $msix
