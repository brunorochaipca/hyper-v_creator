<#
.SYNOPSIS
  Cria uma VM Hyper-V com o Windows 10 22H2 e instala-o.

.DESCRIPTION
  Adaptado de https://gist.github.com/jhochwald/bc968bfafaef0359ce2e2913bb703f9e
  Descarrega o ISO oficial (Windows 10 22H2, Home/Pro/Edu, português de Portugal, x64)
  pelos servidores da Microsoft, via Fido (https://github.com/pbatard/Fido). Copia o
  Windows 10 Pro para o disco da VM nesta máquina, por isso a VM arranca já no Windows
  e não entra no instalador. A primeira sessão ainda mostra "A preparar o Windows" e
  entra com a conta local. A chave pública do Windows 10 Pro não ativa o Windows.

  Corre numa consola elevada (o Hyper-V exige administrador).

.EXAMPLE
  .\win10vm.ps1 -Client LABWIN10

.EXAMPLE
  .\win10vm.ps1 -Client LABWIN10 -IsoPath D:\ISO\Win10.iso -VSwitch 'Default Switch'
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Client,

    [string]$Path,

    [ValidateRange(40, 2000)]
    [int]$DiskSize = 100,

    [ValidateRange(2, 64)]
    [int]$StartMem = 4,

    [ValidateRange(2, 64)]
    [int]$MaxMem = 8,

    [ValidateRange(1, 64)]
    [int]$Processors = 4,

    [string]$VSwitch,

    [ValidateSet(1, 2)]
    [int]$Generation = 2,

    [string]$UserName = "Lab",

    [string]$Password = "Lab12345",

    # Expressão usada pelo Fido. ^Portuguese$ é Portugal; o Brasil é "Portuguese (Brazil)".
    [string]$Language = "^Portuguese$",

    # Imagem dentro do ISO. No ISO da Microsoft o nome fica em inglês.
    [string]$ImageName = "Windows 10 Pro",

    # Se o ISO já estiver descarregado, passa o caminho e o Fido não corre.
    [string]$IsoPath
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-XmlText([string]$Value) {
    return $Value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Get-SafeComputerName([string]$Name) {
    $clean = ($Name -replace "[^A-Za-z0-9-]", "")
    if (-not $clean) { $clean = "WIN10VM" }
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15) }
    return $clean
}

function Get-MicrosoftIso([string]$Destination, [string]$FidoLanguage) {
    if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 4GB)) {
        Write-Host "ISO já presente: $Destination"
        return
    }
    if (Test-Path $Destination) { Remove-Item $Destination -Force }

    $fido = Join-Path $env:TEMP "Fido.ps1"
    Write-Host "A obter o Fido..."
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1" -OutFile $fido

    Write-Host "A pedir o link do ISO à Microsoft (Windows 10 22H2, $FidoLanguage, x64)..."
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fido -Win "10" -Rel "22H2" -Ed "Home/Pro" -Lang $FidoLanguage -Arch "x64" -GetUrl
    if ($LASTEXITCODE -ne 0) {
        throw "O Fido não devolveu o link (código $LASTEXITCODE).`n$($output -join "`n")`nLista de línguas: powershell -File `"$fido`" -Win 10 -Rel 22H2 -Ed Home/Pro -Lang List"
    }
    $url = @($output) | Where-Object { "$_" -match "^https://" } | Select-Object -Last 1
    if (-not $url) {
        throw "A resposta da Microsoft não trouxe um link.`n$($output -join "`n")"
    }

    Write-Host "A descarregar o ISO para $Destination"
    Write-Host "O link da Microsoft expira ao fim de 24 horas. Se a descarga falhar, volta a correr o script."
    Import-Module BitsTransfer
    Start-BitsTransfer -Source $url -Destination $Destination
}

function Get-UnattendXml([string]$ComputerName, [string]$Account, [string]$AccountPassword) {
    $computer = ConvertTo-XmlText $ComputerName
    $account = ConvertTo-XmlText $Account
    $secret = ConvertTo-XmlText $AccountPassword

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$computer</ComputerName>
      <TimeZone>GMT Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0816:00000816</InputLocale>
      <SystemLocale>pt-PT</SystemLocale>
      <UILanguage>pt-PT</UILanguage>
      <UserLocale>pt-PT</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$account</Name>
            <Group>Administrators</Group>
            <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$account</Username>
        <Password><Value>$secret</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@
}

function Get-FreeDriveLetter([string[]]$Reserved) {
    $used = @((Get-PSDrive -PSProvider FileSystem).Name) + @($Reserved)
    foreach ($letter in [char[]]([char]'W'..[char]'Z') + [char[]]([char]'D'..[char]'V')) {
        $name = [string]$letter
        if ($used -notcontains $name) { return $name }
    }
    throw "Não há letras de unidade livres."
}

# Writes Windows onto the VHD from this machine, so the VM never boots the installer.
function Install-WindowsOffline([string]$DiskPath, [string]$Iso, [int]$VmGeneration, [string]$EditionName, [string]$UnattendXml) {
    $isoMounted = $false
    $vhdMounted = $false
    try {
        Write-Host "A montar o ISO..."
        $isoImage = Mount-DiskImage -ImagePath $Iso -PassThru
        $isoMounted = $true
        $isoLetter = ($isoImage | Get-Volume).DriveLetter
        if (-not $isoLetter) { throw "Não foi possível ler o ISO." }
        $imageFile = @("install.wim", "install.esd") |
            ForEach-Object { Join-Path "${isoLetter}:\sources" $_ } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if (-not $imageFile) { throw "O ISO não contém sources\install.wim nem sources\install.esd." }
        $edition = Get-WindowsImage -ImagePath $imageFile | Where-Object { $_.ImageName -eq $EditionName } | Select-Object -First 1
        if (-not $edition) {
            $names = (Get-WindowsImage -ImagePath $imageFile | ForEach-Object { $_.ImageName }) -join ", "
            throw "A edição '$EditionName' não está no ISO. Edições disponíveis: $names"
        }

        Write-Host "A preparar o disco..."
        $vhd = Mount-VHD -Path $DiskPath -Passthru
        $vhdMounted = $true
        $windowsLetter = Get-FreeDriveLetter
        $systemLetter = Get-FreeDriveLetter -Reserved $windowsLetter
        if ($VmGeneration -eq 2) {
            $partition = @"
select disk $($vhd.DiskNumber)
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label=System
assign letter=$systemLetter
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter=$windowsLetter
exit
"@
            $firmware = "UEFI"
        } else {
            $partition = @"
select disk $($vhd.DiskNumber)
clean
convert mbr
create partition primary size=100
format quick fs=ntfs label=System
assign letter=$systemLetter
active
create partition primary
format quick fs=ntfs label=Windows
assign letter=$windowsLetter
exit
"@
            $firmware = "BIOS"
        }
        $partitionResult = $partition | diskpart.exe | Out-String
        if ($partitionResult -match "error|erro") { throw "O diskpart falhou.`n$partitionResult" }
        if (-not (Test-Path "${windowsLetter}:\")) { throw "A unidade do Windows não ficou disponível.`n$partitionResult" }

        Write-Host "A copiar o $EditionName para o disco. Demora vários minutos..."
        Expand-WindowsImage -ImagePath $imageFile -Index $edition.ImageIndex -ApplyPath "${windowsLetter}:\"
        $bcdboot = "${windowsLetter}:\Windows\System32\bcdboot.exe"
        & $bcdboot "${windowsLetter}:\Windows" /s "${systemLetter}:" /f $firmware | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "O bcdboot falhou com o código $LASTEXITCODE." }

        $panther = "${windowsLetter}:\Windows\Panther"
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $panther "unattend.xml"), $UnattendXml, [Text.UTF8Encoding]::new($false))
    } finally {
        if ($vhdMounted) { Dismount-VHD -Path $DiskPath -ErrorAction SilentlyContinue }
        if ($isoMounted) { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue }
    }
}

if (-not (Test-Administrator)) {
    throw "Corre este script numa consola de administrador. O Hyper-V não cria máquinas sem elevação."
}

Import-Module Hyper-V

if (-not $Path) {
    $Path = (Get-VMHost).VirtualHardDiskPath
}
if (-not $Path) {
    $Path = "C:\Hyper-V\Virtual Hard Disks"
}
New-Item -ItemType Directory -Path $Path -Force | Out-Null

if (-not $VSwitch) {
    $switches = @(Get-VMSwitch)
    $VSwitch = @($switches | Where-Object { $_.Name -eq "Default Switch" } | Select-Object -First 1).Name
    if (-not $VSwitch -and $switches.Count -gt 0) { $VSwitch = $switches[0].Name }
}
if (-not $VSwitch) {
    throw "Não há nenhum comutador Hyper-V. Cria um no Gestor do Hyper-V ou passa -VSwitch."
}

if (Get-VM -Name $Client -ErrorAction SilentlyContinue) {
    throw "Já existe uma VM chamada '$Client'."
}

$computerName = Get-SafeComputerName $Client
$disk = Join-Path $Path "$Client.vhdx"
if (-not $IsoPath) {
    $IsoPath = Join-Path $Path "Win10_22H2_pt-PT_x64.iso"
}
if (Test-Path $disk) { throw "O disco já existe: $disk" }

Get-MicrosoftIso -Destination $IsoPath -FidoLanguage $Language

Write-Host "A criar o disco de '$Client'..."
New-VHD -Path $disk -Dynamic -SizeBytes ($DiskSize * 1GB) | Out-Null
$xml = Get-UnattendXml -ComputerName $computerName -Account $UserName -AccountPassword $Password
Install-WindowsOffline -DiskPath $disk -Iso $IsoPath -VmGeneration $Generation -EditionName $ImageName -UnattendXml $xml

Write-Host "A criar a VM '$Client'..."
New-VM -Name $Client -MemoryStartupBytes ($StartMem * 1GB) -VHDPath $disk -SwitchName $VSwitch -Generation $Generation | Out-Null
Set-VMMemory -VMName $Client -DynamicMemoryEnabled $true -MinimumBytes ($StartMem * 1GB) -StartupBytes ($StartMem * 1GB) -MaximumBytes ($MaxMem * 1GB)
Set-VMProcessor -VMName $Client -Count $Processors
if ($Generation -eq 2) {
    Set-VMFirmware -VMName $Client -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
}

Start-VM -Name $Client
Start-Process vmconnect.exe -ArgumentList "localhost", $Client

Write-Host ""
Write-Host "A VM '$Client' está a arrancar com o Windows já instalado."
Write-Host "A primeira vez mostra 'A preparar o Windows' e entra sozinha."
Write-Host "Conta local: $UserName"
Write-Host "Palavra-passe: $Password"
Write-Host "O Windows não fica ativado."
Write-Host "ISO: $IsoPath"
