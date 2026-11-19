# Publica a aplicação e gera um MSIX autoassinado mais o .cer público.
# Quem instala confia nesse .cer com Trust My Msix (https://github.com/Chill-Astro/Trust-My-Msix):
#   winget install Chill-Astro.TMM
#   tmm --i .\CriarVmWindows.cer
# -Confiar corre o tmm --i nesta máquina depois de empacotar.

param(
    [switch]$Confiar,
    [string]$Conteudo,
    [string]$Versao
)

$ErrorActionPreference = "Stop"

$publisher = "CN=CriarVmWindows"
$root = Split-Path -Parent $PSScriptRoot
$csproj = Join-Path $root "src\CriarVmWindows\CriarVmWindows.csproj"
$publishDir = Join-Path $root "publish"
$layout = Join-Path $PSScriptRoot "msix-layout"
$certDir = Join-Path $PSScriptRoot "certs"
$pfx = Join-Path $certDir "CriarVmWindows.pfx"
$passwordFile = Join-Path $certDir "password.txt"
$cer = Join-Path $PSScriptRoot "CriarVmWindows.cer"
$msix = Join-Path $PSScriptRoot "CriarVmWindows.msix"

function ConvertTo-AppxVersion {
    param([string]$Raw)
    $parts = $Raw.Trim().TrimStart("vV").Split(".")
    while ($parts.Count -lt 4) { $parts += "0" }
    return ($parts | Select-Object -First 4) -join "."
}

function Get-AppxVersion {
    if ($Versao) { return ConvertTo-AppxVersion $Versao }
    $text = Get-Content -Raw -Path $csproj
    if ($text -notmatch "<Version>([^<]+)</Version>") {
        throw "Não encontrei <Version> em $csproj."
    }
    return ConvertTo-AppxVersion $Matches[1]
}

function New-Logo {
    param([string]$Path, [int]$Size)
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = "AntiAlias"
    $graphics.TextRenderingHint = "AntiAliasGridFit"
    $graphics.Clear([System.Drawing.Color]::FromArgb(255, 0, 99, 177))
    $fontSize = [Math]::Max(10, [int]($Size * 0.32))
    $font = New-Object System.Drawing.Font "Segoe UI", $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 0, $Size, $Size
    $graphics.DrawString("VM", $font, [System.Drawing.Brushes]::White, $rect, $format)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $font.Dispose()
    $bitmap.Dispose()
}

function Find-SdkTool {
    param([string]$Name)
    $nugetRoots = @()
    if ($env:NUGET_PACKAGES) { $nugetRoots += $env:NUGET_PACKAGES }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $locals = dotnet nuget locals global-packages -l 2>$null
        if ($locals -match "global-packages:\s*(.+)") { $nugetRoots += $Matches[1].Trim() }
    }
    $nugetRoots += Join-Path $env:USERPROFILE ".nuget\packages"
    $candidates = @()
    foreach ($root in ($nugetRoots | Select-Object -Unique)) {
        $package = Join-Path $root "microsoft.windows.sdk.buildtools"
        if (Test-Path -LiteralPath $package) {
            $candidates += Get-ChildItem -Path $package -Recurse -Filter $Name -ErrorAction SilentlyContinue
        }
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kits) {
        $candidates += Get-ChildItem -Path $kits -Recurse -Filter $Name -ErrorAction SilentlyContinue
    }
    $tool = $candidates |
        Where-Object { $_.FullName -match "\\x64\\" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $tool) {
        throw "Não encontrei $Name. Instala o Windows SDK, ou restaura os pacotes do projeto com dotnet restore."
    }
    return $tool.FullName
}

function Get-SigningCert {
    if (-not (Test-Path -LiteralPath $certDir)) {
        New-Item -ItemType Directory -Path $certDir | Out-Null
    }

    if ((Test-Path -LiteralPath $pfx) -and (Test-Path -LiteralPath $passwordFile)) {
        $password = (Get-Content -Raw -Path $passwordFile).Trim()
        $secure = ConvertTo-SecureString $password -AsPlainText -Force
        return Import-PfxCertificate -FilePath $pfx -Password $secure -CertStoreLocation "Cert:\CurrentUser\My"
    }

    $password = [guid]::NewGuid().ToString("N")
    Set-Content -Path $passwordFile -Value $password -NoNewline
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $publisher `
        -KeyUsage DigitalSignature `
        -FriendlyName "CriarVmWindows MSIX" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
        -NotAfter (Get-Date).AddYears(5)
    if ($cert.Subject -ne $publisher) {
        throw "O certificado ficou com o sujeito '$($cert.Subject)' e o manifesto exige '$publisher'."
    }
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
    return $cert
}

$version = Get-AppxVersion
$fonte = $publishDir
if ($Conteudo) {
    $fonte = (Resolve-Path -LiteralPath $Conteudo).Path
    if (-not (Test-Path -LiteralPath (Join-Path $fonte "CriarVmWindows.exe"))) {
        throw "Não encontrei CriarVmWindows.exe em $fonte."
    }
} else {
    if (Test-Path -LiteralPath $layout) {
        Remove-Item -LiteralPath $layout -Recurse -Force
    }
    Write-Host "A publicar a versão $version..."
    dotnet publish $csproj -c Release -p:Platform=x64 -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish falhou com o código $LASTEXITCODE." }
}

if (Test-Path -LiteralPath $layout) {
    Remove-Item -LiteralPath $layout -Recurse -Force
}
New-Item -ItemType Directory -Path $layout | Out-Null

& robocopy $fonte $layout /E /NFL /NDL /NJH /NJS /nc /ns /np /XD msix-layout certs release /XF *.pdb *.msix *.cer | Out-Null
if ($LASTEXITCODE -ge 8) { throw "A cópia para o pacote falhou (robocopy $LASTEXITCODE)." }
$global:LASTEXITCODE = 0

$manifest = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "AppxManifest.xml"))
# Substituição com maiúsculas: o -replace do PowerShell também alteraria <?xml version="1.0".
$manifest = [regex]::Replace($manifest, '(<Identity[^>]*\bVersion=")[^"]+"', '${1}' + $version + '"')
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $layout "AppxManifest.xml"), $manifest.TrimStart([char]0xFEFF), $utf8)

$assets = Join-Path $layout "Assets"
New-Logo (Join-Path $assets "StoreLogo.png") 50
New-Logo (Join-Path $assets "Square44x44Logo.png") 44
New-Logo (Join-Path $assets "Square150x150Logo.png") 150

Write-Host "A criar o certificado de assinatura..."
$cert = Get-SigningCert
Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null

$makeappx = Find-SdkTool "makeappx.exe"
$signtool = Find-SdkTool "signtool.exe"

Write-Host "A gerar o MSIX..."
if (Test-Path -LiteralPath $msix) { Remove-Item -LiteralPath $msix -Force }
& $makeappx pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "makeappx falhou com o código $LASTEXITCODE." }

$password = (Get-Content -Raw -Path $passwordFile).Trim()

function Invoke-SignTool {
    param([string[]]$SignArgs)
    # O signtool escreve o erro no stderr. Com ErrorAction Stop isso aborta
    # antes da segunda tentativa e a mensagem perde-se.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $signtool @SignArgs 2>&1 | Out-String
    $ErrorActionPreference = $previous
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output.Trim() }
}

Write-Host "A assinar o MSIX..."
$signed = Invoke-SignTool @(
    "sign", "/fd", "SHA256", "/f", $pfx, "/p", $password,
    "/tr", "http://timestamp.digicert.com", "/td", "SHA256", $msix
)
if ($signed.Code -ne 0) {
    if ($signed.Output) { Write-Host $signed.Output }
    Write-Host "Sem carimbo de tempo. A assinar outra vez só com o certificado local."
    $signed = Invoke-SignTool @("sign", "/fd", "SHA256", "/f", $pfx, "/p", $password, $msix)
    if ($signed.Code -ne 0) {
        throw "signtool falhou com o código $($signed.Code). $($signed.Output)"
    }
}

Write-Host ""
Write-Host "Pacote: $msix"
Write-Host "Certificado: $cer"
Write-Host ""
Write-Host "Noutra máquina, o Trust My Msix importa o .cer para as autoridades de raiz fidedignas:"
Write-Host "  winget install Chill-Astro.TMM"
Write-Host "  tmm --i `"$cer`""
Write-Host "  Add-AppxPackage `"$msix`""

if ($Confiar) {
    $tmm = Get-Command tmm -ErrorAction SilentlyContinue
    if (-not $tmm) {
        $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\tmm.exe"
        if (Test-Path -LiteralPath $alias) { $tmm = $alias }
    }
    if (-not $tmm) {
        Write-Host "A instalar Trust My Msix..."
        winget install --id Chill-Astro.TMM -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget não instalou Chill-Astro.TMM (código $LASTEXITCODE)." }
        $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\tmm.exe"
        if (Test-Path -LiteralPath $alias) { $tmm = $alias }
        else { $tmm = "tmm" }
    }
    Write-Host "A confiar no certificado com tmm --i ..."
    & $tmm --i $cer
    if ($LASTEXITCODE -ne 0) { throw "tmm falhou com o código $LASTEXITCODE." }
}
