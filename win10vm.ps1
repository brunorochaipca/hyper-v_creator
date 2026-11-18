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

function Get-RemoteLogonScript([string]$Account, [string]$Password) {
    $safeAccount = $Account.Replace("'", "''")
    $safePassword = $Password.Replace("'", "''")
    return @"
`$ErrorActionPreference = 'Continue'
`$name = '$safeAccount'
`$password = '$safePassword'
`$deadline = (Get-Date).AddMinutes(3)
do {
  if (-not (Get-LocalUser -Name `$name -ErrorAction SilentlyContinue)) {
    `$secret = ConvertTo-SecureString `$password -AsPlainText -Force
    New-LocalUser -Name `$name -Password `$secret -PasswordNeverExpires -ErrorAction SilentlyContinue | Out-Null
  }
  `$user = Get-LocalUser -Name `$name -ErrorAction SilentlyContinue
  if (`$user) {
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member `$user -ErrorAction SilentlyContinue
    Add-LocalGroupMember -SID 'S-1-5-32-555' -Member `$user -ErrorAction SilentlyContinue
    try {
      `$computer = [ADSI]'WinNT://.'
      `$account = `$null
      foreach (`$child in `$computer.Children) {
        if (`$child.SchemaClassName -eq 'User' -and `$child.Name -eq `$name) { `$account = `$child; break }
      }
      if (`$account) {
        foreach (`$sid in 'S-1-5-32-544','S-1-5-32-555') {
          `$groupName = (Get-LocalGroup -SID `$sid).Name
          `$group = [ADSI]('WinNT://./' + `$groupName + ',group')
          `$group.Add(`$account.Path)
        }
      }
    } catch { }
    `$export = Join-Path `$env:TEMP 'rdp-rights-export.inf'
    secedit /export /cfg `$export /areas USER_RIGHTS | Out-Null
    `$found = Select-String -Path `$export -Pattern '^SeRemoteInteractiveLogonRight\s*=' | Select-Object -First 1
    `$line = if (`$found) { `$found.Line.Trim() } else { 'SeRemoteInteractiveLogonRight =' }
    `$sid = '*' + `$user.Sid.Value
    if (`$line -notlike "*`$sid*") {
      if (`$line.EndsWith('=')) { `$line += " `$sid" } else { `$line += ",`$sid" }
    }
    `$inf = Join-Path `$env:TEMP 'rdp-rights.inf'
    @(
      '[Unicode]'
      'Unicode=yes'
      '[Version]'
      'signature="`$CHICAGO`$"
      'Revision=1'
      '[Privilege Rights]'
      `$line
    ) | Set-Content -Path `$inf -Encoding Unicode
    secedit /configure /db (Join-Path `$env:TEMP 'rdp-rights.sdb') /cfg `$inf /areas USER_RIGHTS | Out-Null
  }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt `$deadline)
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -PropertyType DWord -Value 0 -Force | Out-Null
"@
}

function Get-UnattendXml([string]$ComputerName, [string]$Account, [string]$AccountPassword) {
    $computer = ConvertTo-XmlText $ComputerName
    $account = ConvertTo-XmlText $Account
    $secret = ConvertTo-XmlText $AccountPassword
    $remoteLogon = "C:\Windows\Setup\Scripts\Grant-HyperVSession.cmd"

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
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>$remoteLogon</Path>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@
}

function Mount-WindowsIso([string]$Iso) {
    $image = Get-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue
    if (-not $image -or -not $image.Attached) {
        Mount-DiskImage -ImagePath $Iso | Out-Null
        $image = Get-DiskImage -ImagePath $Iso
    }
    $volume = @($image | Get-Volume | Where-Object { $_.FileSystem -or $_.Size -gt 0 } | Select-Object -First 1)
    if (-not $volume) { throw "O ISO não tem um volume legível." }

    $letter = [string]$volume.DriveLetter
    if ($letter -and $letter -ne [string][char]0 -and (Test-Path "${letter}:\")) {
        return $letter
    }

    $letter = Get-FreeDriveLetter
    $id = [string]$volume.UniqueId
    if (-not $id) { $id = [string]$volume.Path }
    if ($id -and -not $id.EndsWith("\")) { $id += "\" }
    if (-not $id) { throw "O ISO foi montado, mas o Windows não devolveu o volume." }
    & mountvol.exe "${letter}:" $id | Out-Null
    if (-not (Test-Path "${letter}:\")) {
        throw "O ISO foi montado, mas não ficou acessível numa letra de unidade."
    }
    return $letter
}

function Get-FreeDriveLetter([string[]]$Reserved) {
    $used = @((Get-PSDrive -PSProvider FileSystem).Name) + @($Reserved)
    foreach ($letter in [char[]]([char]'W'..[char]'Z') + [char[]]([char]'D'..[char]'V')) {
        $name = [string]$letter
        if ($used -notcontains $name) { return $name }
    }
    throw "Não há letras de unidade livres."
}

function Initialize-DriveLetterApi {
    if ("Win32.DriveLetters" -as [type]) { return }
    Add-Type -Namespace Win32 -Name DriveLetters -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool DefineDosDevice(uint flags, string device, string target);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint QueryDosDevice(string name, System.Text.StringBuilder path, uint max);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern void SHChangeNotify(int eventId, uint flags, string item, System.IntPtr item2);
"@
}

function Get-FreeMemoryBytes {
    return [int64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
}

# O contador vem em MB. "Memória disponível" acompanha a RAM total e não serve;
# o valor utilizável é o mais baixo que ainda é memória a sério, não uma percentagem.
function Get-BytesAvailableForVm {
    $setNames = @(
        "Hyper-V Dynamic Memory Balancer",
        "Balanceador de Memória Dinâmica Hyper-V"
    )
    $set = $null
    foreach ($name in $setNames) {
        $set = Get-Counter -ListSet $name -ErrorAction SilentlyContinue
        if ($set) { break }
    }

    $totalMb = [int64]((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1024)
    if ($set) {
        $samples = @(Get-Counter -Counter $set.Paths -ErrorAction SilentlyContinue).CounterSamples
        $usable = @($samples | Where-Object {
            $_.CookedValue -ge 256 -and [math]::Abs($_.CookedValue - $totalMb) -gt ($totalMb * 0.05)
        } | Sort-Object CookedValue)
        if ($usable.Count -gt 0) {
            return [int64]$usable[0].CookedValue * 1MB
        }
    }

    $free = Get-FreeMemoryBytes
    $reserve = 512MB
    if ($free -le $reserve) { return $free }
    return $free - $reserve
}

function Stop-IfMemoryIsLow([int]$StartupGb, [string]$AlreadyCreated) {
    $needed = [int64]$StartupGb * 1GB
    $available = Get-BytesAvailableForVm
    if ($available -ge $needed) { return }

    $freeGb = [math]::Round((Get-FreeMemoryBytes) / 1GB, 1)
    $hyperGb = [math]::Round($available / 1GB, 1)
    if ($AlreadyCreated) {
        throw "MEMORIA: A VM '$AlreadyCreated' ficou criada, mas não a iniciei. Não há memória RAM livre suficiente: a VM precisa de $StartupGb GB, o Windows tem cerca de $freeGb GB livres e o Hyper-V pode atribuir cerca de $hyperGb GB. Liberta memória RAM, fecha outros programas, e inicia a VM no Gestor do Hyper-V."
    }
    throw "MEMORIA: Não há memória RAM livre suficiente para iniciar a VM. Ela precisa de $StartupGb GB, o Windows tem cerca de $freeGb GB livres e o Hyper-V pode atribuir cerca de $hyperGb GB. Liberta memória RAM, fecha outros programas, e tenta outra vez."
}

function Remove-AssignedDriveLetter([string]$Letter) {
    if ([string]::IsNullOrWhiteSpace($Letter)) { return }
    $name = $Letter.Trim().TrimEnd(":").Substring(0, 1).ToUpperInvariant()
    if ($name -eq "C") { return }

    Initialize-DriveLetterApi
    $root = "${name}:\"
    foreach ($partition in @(Get-Partition -DriveLetter $name -ErrorAction SilentlyContinue)) {
        Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $root -ErrorAction SilentlyContinue
    }

    & mountvol.exe $root /D | Out-Null

    $buffer = New-Object System.Text.StringBuilder 1024
    $found = [Win32.DriveLetters]::QueryDosDevice("${name}:", $buffer, 1024)
    if ($found -gt 0) {
        $target = $buffer.ToString()
        # 1 = caminho literal, 2 = remover, 4 = só se o destino coincidir.
        [Win32.DriveLetters]::DefineDosDevice(7, "${name}:", $target) | Out-Null
    }

    $regName = "\DosDevices\${name}:"
    if ((Get-Item "HKLM:\SYSTEM\MountedDevices").GetValueNames() -contains $regName) {
        $still = [Win32.DriveLetters]::QueryDosDevice("${name}:", $buffer, 1024)
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${name}:'" -ErrorAction SilentlyContinue
        $usable = $disk -and ($disk.FileSystem -or $disk.Size)
        if ($still -eq 0 -or -not $usable) {
            Remove-ItemProperty -Path "HKLM:\SYSTEM\MountedDevices" -Name $regName -ErrorAction SilentlyContinue
        }
    }

    # 0x80 = unidade removida. 0x5 = o texto é um caminho.
    [Win32.DriveLetters]::SHChangeNotify(0x80, 0x5, $root, [IntPtr]::Zero)
}

function Test-SameDiskPath([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    $clean = {
        param($Value)
        $text = [string]$Value
        if ($text.StartsWith("\\?\")) { $text = $text.Substring(4) }
        try { return [IO.Path]::GetFullPath($text) } catch { return $text }
    }
    $a = & $clean $Left
    $b = & $clean $Right
    if ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return [string]::Equals([IO.Path]::GetFileName($a), [IO.Path]::GetFileName($b), [StringComparison]::OrdinalIgnoreCase)
}

function Test-VhdOwnedByVm([string]$DiskPath) {
    $name = [IO.Path]::GetFileName($DiskPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    foreach ($drive in @(Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
        if (-not $drive.Path) { continue }
        if (Test-SameDiskPath $drive.Path $DiskPath) { return $true }
        $file = [IO.Path]::GetFileName($drive.Path)
        if ($file -like "${stem}_*.avhdx") { return $true }
    }
    return $false
}

function Get-HostMountedVhd([string]$DiskPath) {
    if (-not $DiskPath) { return $null }
    foreach ($disk in @(Get-Disk -ErrorAction SilentlyContinue)) {
        if ([string]$disk.BusType -ne "FileBackedVirtual" -or -not $disk.Location) { continue }
        if (-not (Test-SameDiskPath $disk.Location $DiskPath)) { continue }
        $system = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue) |
            Where-Object { $_.DriveLetter -eq "C" }
        if ($system) { continue }
        return $disk
    }
    return $null
}

function Wait-VhdReleased([string]$DiskPath) {
    if (-not $DiskPath -or -not (Test-Path -LiteralPath $DiskPath)) { return }
    if (Test-VhdOwnedByVm $DiskPath) { return }

    for ($try = 1; $try -le 8; $try++) {
        $hostDisk = Get-HostMountedVhd $DiskPath
        if ($hostDisk) {
            foreach ($partition in @(Get-Partition -DiskNumber $hostDisk.Number -ErrorAction SilentlyContinue)) {
                if ($partition.DriveLetter -and $partition.DriveLetter -ne [char]0) {
                    Remove-AssignedDriveLetter ([string]$partition.DriveLetter)
                }
            }
        }
        Dismount-VHD -Path $DiskPath -ErrorAction SilentlyContinue
        $stillHosted = Get-HostMountedVhd $DiskPath
        if ($stillHosted) {
            $detach = @"
select vdisk file="$DiskPath"
detach vdisk
exit
"@
            $detach | diskpart.exe | Out-Null
        }

        $open = Get-VHD -Path $DiskPath -ErrorAction SilentlyContinue
        $free = $false
        if (-not $open -or -not $open.Attached) {
            try {
                $stream = [IO.File]::Open($DiskPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                $stream.Dispose()
                $free = $true
            } catch {
                $free = $false
            }
        }
        if ($free) { return }
        Start-Sleep -Seconds 1
    }

    throw "O disco ainda está aberto neste Windows, por isso a VM não o consegue usar. Fecha janelas do Explorador que estejam nesse disco e tenta outra vez."
}

function Clear-WorkingMounts([string]$DiskPath, [string]$IsoPath, [string[]]$Letters) {
    try {
    foreach ($letter in @($Letters)) { Remove-AssignedDriveLetter $letter }

    if ($IsoPath -and (Test-Path -LiteralPath $IsoPath)) {
        $image = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        if ($image -and $image.Attached) {
            $volume = $image | Get-Volume -ErrorAction SilentlyContinue
            if ($volume.DriveLetter) { Remove-AssignedDriveLetter ([string]$volume.DriveLetter) }
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        }
    }

    foreach ($letter in @($Letters)) { Remove-AssignedDriveLetter $letter }
    } catch {
        Write-Host "Não consegui libertar todas as unidades montadas: $($_.Exception.Message)"
    }
}

# Writes Windows onto the VHD from this machine, so the VM never boots the installer.
function Install-WindowsOffline([string]$DiskPath, [string]$Iso, [int]$VmGeneration, [string]$EditionName, [string]$UnattendXml, [string]$SetupScript) {
    $isoMounted = $false
    $vhdMounted = $false
    $letters = @()
    try {
        Write-Host "A montar o ISO..."
        $isoLetter = Mount-WindowsIso $Iso
        $isoMounted = $true
        $letters += [string]$isoLetter
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
        $vhd = Mount-VHD -Path $DiskPath -NoDriveLetter -Passthru
        $vhdMounted = $true
        $windowsLetter = Get-FreeDriveLetter
        $systemLetter = Get-FreeDriveLetter -Reserved $windowsLetter
        $letters += $windowsLetter, $systemLetter
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
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $panther "unattend.xml"), $UnattendXml, $utf8)
        if ($SetupScript) {
            $scripts = "${windowsLetter}:\Windows\Setup\Scripts"
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $scripts "Grant-HyperVSession.ps1"), $SetupScript, [Text.UTF8Encoding]::new($true))
            $launcher = @"
@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Setup\Scripts\Grant-HyperVSession.ps1
"@
            [IO.File]::WriteAllText((Join-Path $scripts "Grant-HyperVSession.cmd"), $launcher, [Text.Encoding]::ASCII)
        }
    } finally {
        $vhd = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Clear-WorkingMounts -DiskPath $(if ($vhdMounted) { $DiskPath } else { $null }) -IsoPath $(if ($isoMounted) { $Iso } else { $null }) -Letters $letters
        if ($vhdMounted) { Wait-VhdReleased $DiskPath }
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

Stop-IfMemoryIsLow -StartupGb $StartMem

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
$setupScript = Get-RemoteLogonScript -Account $UserName -Password $Password
try {
    Install-WindowsOffline -DiskPath $disk -Iso $IsoPath -VmGeneration $Generation -EditionName $ImageName -UnattendXml $xml -SetupScript $setupScript
    Wait-VhdReleased $disk

    Write-Host "A criar a VM '$Client'..."
    New-VM -Name $Client -MemoryStartupBytes ($StartMem * 1GB) -VHDPath $disk -SwitchName $VSwitch -Generation $Generation | Out-Null
    Set-VMMemory -VMName $Client -DynamicMemoryEnabled $true -MinimumBytes ($StartMem * 1GB) -StartupBytes ($StartMem * 1GB) -MaximumBytes ($MaxMem * 1GB)
    Set-VMProcessor -VMName $Client -Count $Processors
    if ($Generation -eq 2) {
        Set-VMFirmware -VMName $Client -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    }
    if ((Get-Command Set-VM).Parameters.ContainsKey("AutomaticCheckpointsEnabled")) {
        Set-VM -Name $Client -AutomaticCheckpointsEnabled $false
    }

    Stop-IfMemoryIsLow -StartupGb $StartMem -AlreadyCreated $Client

    Start-VM -Name $Client
} finally {
    Clear-WorkingMounts -IsoPath $IsoPath
}
Start-Process vmconnect.exe -ArgumentList "localhost", $Client

Write-Host ""
Write-Host "A VM '$Client' está a arrancar com o Windows já instalado."
Write-Host "A primeira vez mostra 'A preparar o Windows' e entra sozinha."
Write-Host "Conta local: $UserName"
Write-Host "Palavra-passe: $Password"
Write-Host "O Windows não fica ativado."
Write-Host "ISO: $IsoPath"
