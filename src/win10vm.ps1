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
    # Obrigatório, exceto com -ListEditions (ver a verificação mais abaixo).
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Client,

    # Só lista as edições do ISO indicado em -IsoPath (uma por linha, "EDICAO:nome") e termina.
    [switch]$ListEditions,

    # Só arranca a VM -Client que já existe (por exemplo, depois de faltar memória) e abre a ligação.
    [switch]$StartExisting,

    # Repara a sessão avançada da VM -Client que já existe: desliga-a, mete a conta -UserName nos
    # Administradores e no Ambiente de Trabalho Remoto através de um script de arranque, e volta a ligá-la.
    # Se -Password for dado, confirma o resultado dentro da VM.
    [switch]$FixSession,

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
    [string]$IsoPath,

    # SHA-256 esperado do ISO (opcional). Se for dado e não coincidir, a criação para antes de gastar tempo.
    [ValidatePattern('^([0-9A-Fa-f]{64})?$')]
    [string]$IsoSha256
)

$ErrorActionPreference = "Stop"

# O Fido é descarregado de uma versão fixa e o ficheiro é verificado, em vez de usar o "master".
# Para atualizar: escolhe uma versão em https://github.com/pbatard/Fido/releases e calcula o SHA-256 do Fido.ps1 dessa versão.
$FidoVersion = "v1.72"
$FidoCommit = "266084e3765ab8bf96767bd55c51b0ee70934551"
$FidoSha256 = "89A26B4A8BE2721E610BA3F563EC44024E6CF7975938EE5B61D624D2BFBF4643"

# Espaço mínimo estimado: o Windows 10 aplicado ocupa cerca de 15 GB e o disco dinâmico cresce com o uso.
$WindowsNeedGb = 20
$IsoNeedGb = 6
$script:IsoWasDownloaded = $false

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-XmlText([string]$Value) {
    return $Value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Get-SafeComputerName([string]$Name, [string]$Account) {
    $clean = ($Name -replace "[^A-Za-z0-9-]", "")
    if (-not $clean) { $clean = "WIN10VM" }
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15) }

    # Se a conta tiver o nome do computador, o Windows resolve o nome como a conta do próprio
    # computador e recusa pô-la nos Administradores («failed to add ... 0x8007056b»). Sem
    # administrador, a sessão avançada diz que falta o direito de iniciar sessão remota.
    if ($Account -and [string]::Equals($clean, ($Account -replace "[^A-Za-z0-9-]", ""), [StringComparison]::OrdinalIgnoreCase)) {
        $suffix = "-PC"
        if ($clean.Length + $suffix.Length -gt 15) { $clean = $clean.Substring(0, 15 - $suffix.Length) }
        $clean += $suffix
        Write-Host "O nome do computador será '$clean', porque a conta '$Account' não pode ter o mesmo nome que ele."
    }
    return $clean
}

function Get-MicrosoftIso([string]$Destination, [string]$FidoLanguage) {
    if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 4GB)) {
        Write-Host "ISO já presente: $Destination"
        return
    }
    if (Test-Path $Destination) { Remove-Item $Destination -Force }

    $fido = Join-Path $env:TEMP "Fido-$FidoVersion.ps1"
    Write-Host "A obter o Fido $FidoVersion..."
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/pbatard/Fido/$FidoCommit/Fido.ps1" -OutFile $fido
    $fidoHash = (Get-FileHash -LiteralPath $fido -Algorithm SHA256).Hash
    if ($fidoHash -ne $FidoSha256) {
        Remove-Item -LiteralPath $fido -Force -ErrorAction SilentlyContinue
        throw "INTEGRIDADE: O Fido descarregado não é o esperado (SHA-256 $fidoHash em vez de $FidoSha256). Por segurança não foi executado."
    }

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
    $script:IsoWasDownloaded = $true
    Import-Module BitsTransfer
    # A descarga corre em segundo plano para se poder comunicar o progresso (##DESCARGA:percentagem|MB feitos|MB totais).
    $job = Start-BitsTransfer -Source $url -Destination $Destination -DisplayName "CriarVmWindows" -Asynchronous
    try {
        while ($true) {
            $job = Get-BitsTransfer -JobId $job.JobId
            $state = [string]$job.JobState
            if ($state -eq "Transferred") { break }
            if ($state -in "Error", "Cancelled") {
                throw "A descarga do ISO falhou ($state). $($job.ErrorDescription)"
            }
            if ($state -eq "Suspended") { Resume-BitsTransfer -BitsJob $job -Asynchronous | Out-Null }
            if ($job.BytesTotal -gt 0 -and $job.BytesTotal -lt [uint64]::MaxValue) {
                $percent = [int](100 * $job.BytesTransferred / $job.BytesTotal)
                $doneMb = [int]($job.BytesTransferred / 1MB)
                $totalMb = [int]($job.BytesTotal / 1MB)
                Write-Host "##DESCARGA:$percent|$doneMb|$totalMb"
            }
            Start-Sleep -Seconds 1
        }
        Complete-BitsTransfer -BitsJob $job
    } catch {
        Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
        throw
    }
}

function Get-DriveRoot([string]$AnyPath) {
    return [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($AnyPath))
}

# Confirma que cada unidade envolvida tem espaço antes de descarregar ou copiar o que for.
function Stop-IfDiskIsLow([string]$VmFolder, [string]$Iso, [bool]$NeedsDownload, [int]$DiskSizeGb) {
    $needs = @{}
    $reasons = @{}
    $vmRoot = Get-DriveRoot $VmFolder
    $needs[$vmRoot] = [int64]$WindowsNeedGb * 1GB
    $reasons[$vmRoot] = @("o Windows instalado (cerca de $WindowsNeedGb GB)")
    if ($NeedsDownload) {
        $isoRoot = Get-DriveRoot $Iso
        $needs[$isoRoot] = [int64]$needs[$isoRoot] + [int64]$IsoNeedGb * 1GB
        $reasons[$isoRoot] = @($reasons[$isoRoot]) + "o ISO (cerca de $IsoNeedGb GB)"
    }

    foreach ($root in $needs.Keys) {
        if ($root.StartsWith("\\")) {
            Write-Host "Aviso: $root é uma pasta de rede, por isso não consigo verificar o espaço livre."
            continue
        }
        $drive = Get-PSDrive -Name $root.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
        if (-not $drive) { continue }
        $free = [int64]$drive.Free
        $needed = [int64]$needs[$root]
        $freeGb = [math]::Round($free / 1GB, 1)
        $neededGb = [math]::Round($needed / 1GB, 1)
        if ($free -lt $needed) {
            $why = @($reasons[$root]) -join " e "
            throw "ESPACO: A unidade $root tem só $freeGb GB livres e são precisos pelo menos $neededGb GB para $why. Liberta espaço ou escolhe outra pasta em Opções avançadas."
        }
        Write-Host "Espaço na unidade ${root}: $freeGb GB livres (precisa de pelo menos $neededGb GB)."
        if ($root -eq $vmRoot -and $free -lt ([int64]$DiskSizeGb * 1GB)) {
            Write-Host "Aviso: o disco da VM pode crescer até $DiskSizeGb GB e a unidade tem menos do que isso livre."
        }
    }
}

# Calcula o SHA-256 quando há um valor esperado ou quando o ISO acabou de ser descarregado.
function Confirm-IsoHash([string]$Iso, [string]$Expected, [bool]$Downloaded) {
    if (-not $Expected -and -not $Downloaded) { return }
    Write-Host "##DETALHE:A verificar o ISO..."
    Write-Host "A calcular o SHA-256 do ISO (demora cerca de um minuto)..."
    $actual = (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash
    Write-Host "SHA-256 do ISO: $actual"
    if ($Expected -and ($actual -ne $Expected.Trim().ToUpperInvariant())) {
        throw "INTEGRIDADE: O SHA-256 do ISO ($actual) não coincide com o esperado ($($Expected.Trim().ToUpperInvariant())). O ISO pode estar corrompido ou não ser o que esperas."
    }
    if ($Expected) { Write-Host "O SHA-256 coincide com o esperado." }
}

# Lê as edições de um ISO montado. $Root pode ser "E:\" ou o caminho do volume (\\?\Volume{...}\).
function Get-IsoEditionNames([string]$Root) {
    $sources = $Root.TrimEnd("\") + "\sources"
    $file = @("install.wim", "install.esd") |
        ForEach-Object { "$sources\$_" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $file) { throw "O ISO não contém sources\install.wim nem sources\install.esd." }
    return @(Get-WindowsImage -ImagePath $file | ForEach-Object { $_.ImageName })
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
        throw "MEMORIA: A VM '$AlreadyCreated' ficou criada, mas não a iniciei. Não há memória RAM livre suficiente: a VM precisa de $StartupGb GB, o Windows tem cerca de $freeGb GB livres e o Hyper-V pode atribuir cerca de $hyperGb GB. Liberta memória RAM, fecha outros programas e tenta iniciar a VM outra vez (botão «Tentar iniciar a VM», ou -StartExisting -Client $AlreadyCreated, ou o Gestor do Hyper-V)."
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
function Install-WindowsOffline([string]$DiskPath, [string]$Iso, [int]$VmGeneration, [string]$EditionName, [string]$UnattendXml) {
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

if ($ListEditions) {
    if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath)) { throw "Indica com -IsoPath um ISO que exista." }
    $listLetter = $null
    $names = @()
    $lastError = $null
    try {
        # O Windows nem sempre atribui uma letra ao ISO montado. O caminho do volume (\\?\Volume{...})
        # funciona sem letra; só se falhar é que se atribui uma letra livre, como na criação.
        $listVolume = Mount-DiskImage -ImagePath $IsoPath -PassThru | Get-Volume | Select-Object -First 1
        $roots = @()
        if ($listVolume.DriveLetter -and $listVolume.DriveLetter -ne [char]0) { $roots += "$($listVolume.DriveLetter):\" }
        if ($listVolume.Path) { $roots += [string]$listVolume.Path }
        foreach ($root in $roots) {
            try { $names = @(Get-IsoEditionNames $root) } catch { $lastError = $_.Exception.Message }
            if ($names.Count -gt 0) { break }
        }
        if ($names.Count -eq 0) {
            $listLetter = Mount-WindowsIso $IsoPath
            $names = @(Get-IsoEditionNames "${listLetter}:\")
        }
        $names | ForEach-Object { Write-Output "EDICAO:$_" }
    } catch {
        if ($lastError -and $_.Exception.Message -like "*letra*") { throw $lastError }
        throw
    } finally {
        Clear-WorkingMounts -IsoPath $IsoPath -Letters @($listLetter)
    }
    exit 0
}

if (-not $Client) { throw "Indica o nome da VM com -Client." }

Import-Module Hyper-V

# Corre dentro do Windows da VM, como sistema, no arranque. A conta entra nos grupos pelo objeto
# (não pelo nome), que é o que funciona mesmo quando o nome da conta coincide com o do computador.
function Get-SessionRepairScript([string]$Account) {
    $safeAccount = $Account.Replace("'", "''")
    return @"
`$ErrorActionPreference = 'Continue'
`$name = '$safeAccount'
`$report = 'C:\Windows\Setup\Scripts\corrigir-sessao.txt'
`$groups = 'S-1-5-32-544', 'S-1-5-32-555'
`$ok = `$false
`$notes = @()
for (`$try = 1; `$try -le 30 -and -not `$ok; `$try++) {
  `$user = Get-LocalUser -Name `$name -ErrorAction SilentlyContinue
  if (`$user) {
    `$missing = 0
    foreach (`$sid in `$groups) {
      `$members = @(Get-LocalGroupMember -SID `$sid -ErrorAction SilentlyContinue | ForEach-Object { `$_.SID.Value })
      if (`$members -notcontains `$user.SID.Value) {
        try { Add-LocalGroupMember -SID `$sid -Member `$user -ErrorAction Stop; `$notes += "`$sid adicionado" }
        catch { `$notes += "`$sid erro: `$(`$_.Exception.Message)" }
        `$members = @(Get-LocalGroupMember -SID `$sid -ErrorAction SilentlyContinue | ForEach-Object { `$_.SID.Value })
        if (`$members -notcontains `$user.SID.Value) { `$missing++ }
      }
    }
    `$ok = (`$missing -eq 0)
  } else { `$notes += 'conta ainda não existe' }
  if (-not `$ok) { Start-Sleep -Seconds 2 }
}
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -PropertyType DWord -Value 0 -Force | Out-Null
`$status = 'FALHOU'
if (`$ok) { `$status = 'OK' }
Set-Content -Path `$report -Value (`$status + ' ' + (`$notes -join ' | '))
if (`$ok) {
  reg.exe delete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v RunStartupScriptSync /f | Out-Null
  Remove-Item 'C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini' -Force -ErrorAction SilentlyContinue
  Remove-Item 'C:\Windows\System32\GroupPolicy\gpt.ini' -Force -ErrorAction SilentlyContinue
}
"@
}

function Invoke-OfflineRegistry([string]$HiveFile, [scriptblock]$Action) {
    $hive = "HKLM\CRIARVM_REPARAR"
    $load = & reg.exe load $hive $HiveFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Não consegui abrir o registo do Windows da VM. $load" }
    try {
        & $Action $hive
    } finally {
        [GC]::Collect()
        $unload = & reg.exe unload $hive 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 2
            [GC]::Collect()
            $unload = & reg.exe unload $hive 2>&1 | Out-String
        }
        if ($LASTEXITCODE -ne 0) { Write-Host "Aviso: o registo da VM ficou aberto ($unload)" }
    }
}

function Repair-AdvancedSession([string]$VmName, [string]$Account, [string]$AccountPassword) {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "A VM '$VmName' não existe no Hyper-V." }
    if (-not $Account) { throw "Indica a conta da VM com -UserName." }

    $drive = @(Get-VMHardDiskDrive -VMName $VmName) | Select-Object -First 1
    if (-not $drive -or -not $drive.Path) { throw "A VM '$VmName' não tem disco." }
    $diskPath = $drive.Path

    Write-Host "A desligar a VM '$VmName'..."
    if ([string]$vm.State -in @("Saved", "Paused")) {
        throw "A VM '$VmName' está em estado '$($vm.State)'. Liga-a e desliga-a no Gestor do Hyper-V e tenta outra vez."
    }
    if ([string]$vm.State -ne "Off") {
        Stop-VM -Name $VmName -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 60 -and [string](Get-VM -Name $VmName).State -ne "Off"; $i++) { Start-Sleep -Seconds 2 }
        if ([string](Get-VM -Name $VmName).State -ne "Off") { Stop-VM -Name $VmName -TurnOff -Force }
    }

    $existingMount = Get-VHD -Path $diskPath
    if ($existingMount.Attached) { Dismount-VHD -Path $diskPath }

    $mounted = $false
    $letter = $null
    try {
        Write-Host "A abrir o disco da VM..."
        Mount-VHD -Path $diskPath -NoDriveLetter
        $mounted = $true
        $diskNumber = (Get-VHD -Path $diskPath).DiskNumber

        foreach ($partition in @(Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Type -eq "Basic" -and $_.Size -gt 5GB })) {
            $candidate = Get-FreeDriveLetter
            Set-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $candidate
            Start-Sleep -Seconds 1
            if (Test-Path "${candidate}:\Windows\System32\config\SOFTWARE") { $letter = $candidate; break }
            Remove-AssignedDriveLetter ([string]$candidate)
        }
        if (-not $letter) { throw "Não encontrei o Windows no disco da VM '$VmName'." }

        $windows = "${letter}:\Windows"
        $policy = Join-Path $windows "System32\GroupPolicy"
        $startupIni = Join-Path $policy "Machine\Scripts\scripts.ini"
        $policyIni = Join-Path $policy "gpt.ini"
        if ((Test-Path -LiteralPath $startupIni) -or (Test-Path -LiteralPath $policyIni)) {
            throw "A VM já tem scripts de arranque definidos por política. Não os altero; corrige a conta dentro da VM."
        }

        Write-Host "A preparar a correção dentro do Windows da VM..."
        $scripts = Join-Path $windows "Setup\Scripts"
        New-Item -ItemType Directory -Path $scripts -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $scripts "CorrigirSessao.ps1"), (Get-SessionRepairScript $Account), [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $scripts "CorrigirSessao.cmd"),
            "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\CorrigirSessao.ps1`r`n",
            [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath (Join-Path $scripts "corrigir-sessao.txt") -Force -ErrorAction SilentlyContinue

        New-Item -ItemType Directory -Path (Join-Path $policy "Machine\Scripts") -Force | Out-Null
        [IO.File]::WriteAllText($startupIni, "[Startup]`r`n0CmdLine=C:\Windows\Setup\Scripts\CorrigirSessao.cmd`r`n0Parameters=`r`n", [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText($policyIni,
            "[General]`r`ngPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]`r`nVersion=9`r`n",
            [Text.Encoding]::ASCII)
        Invoke-OfflineRegistry (Join-Path $windows "System32\config\SOFTWARE") {
            param($hive)
            & reg.exe add "$hive\Microsoft\Windows\CurrentVersion\Policies\System" /v RunStartupScriptSync /t REG_DWORD /d 1 /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Não consegui escrever no registo da VM." }
        }
    } finally {
        $mountedNow = $mounted
        if ($letter) { Remove-AssignedDriveLetter ([string]$letter) }
        if ($mountedNow) {
            Dismount-VHD -Path $diskPath -ErrorAction SilentlyContinue
            if ((Get-VHD -Path $diskPath -ErrorAction SilentlyContinue).Attached) {
                "select vdisk file=`"$diskPath`"`r`ndetach vdisk`r`nexit" | diskpart.exe | Out-Null
            }
        }
    }
    if ((Get-VHD -Path $diskPath).Attached) { throw "O disco da VM continuou aberto neste Windows. Tenta outra vez." }

    $vm = Get-VM -Name $VmName
    $startGb = [int][math]::Ceiling([double]$vm.MemoryStartup / 1GB)
    Stop-IfMemoryIsLow -StartupGb $startGb -AlreadyCreated $VmName

    Write-Host "A ligar a VM '$VmName'. O Windows aplica a correção no arranque..."
    Start-VM -Name $VmName

    if (-not $AccountPassword) {
        Write-Host "A VM '$VmName' foi ligada com a correção. Espera um minuto e abre a sessão avançada."
        return
    }

    $secure = ConvertTo-SecureString $AccountPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Account, $secure)
    $deadline = (Get-Date).AddMinutes(6)
    $report = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $report = Invoke-Command -VMName $VmName -Credential $credential -ErrorAction Stop -ScriptBlock {
                $out = ""
                if (Test-Path "C:\Windows\Setup\Scripts\corrigir-sessao.txt") {
                    $out = (Get-Content "C:\Windows\Setup\Scripts\corrigir-sessao.txt" -Raw).Trim()
                }
                $user = Get-LocalUser -Name $using:Account -ErrorAction SilentlyContinue
                $groups = foreach ($sid in "S-1-5-32-544", "S-1-5-32-555") {
                    $members = @(Get-LocalGroupMember -SID $sid -ErrorAction SilentlyContinue | ForEach-Object { $_.SID.Value })
                    [bool]($user -and ($members -contains $user.SID.Value))
                }
                "ADMIN=$($groups[0]);REMOTO=$($groups[1]);$out"
            }
        } catch {
            $report = $null
        }
        if ($report -and $report -like "ADMIN=True;REMOTO=True*") { break }
    }
    if (-not $report -or $report -notlike "ADMIN=True;REMOTO=True*") {
        throw "Não consegui confirmar a correção dentro da VM. Último estado: $report"
    }
    Write-Host "Confirmado: a conta '$Account' já é administradora e pode usar a sessão avançada."
}

if ($FixSession) {
    $passwordToCheck = if ($PSBoundParameters.ContainsKey("Password")) { $Password } else { $null }
    Repair-AdvancedSession -VmName $Client -Account $UserName -AccountPassword $passwordToCheck
    exit 0
}

if ($StartExisting) {
    $existing = Get-VM -Name $Client -ErrorAction SilentlyContinue
    if (-not $existing) { throw "A VM '$Client' já não existe no Hyper-V." }
    if ([string]$existing.State -eq "Running") {
        Write-Host "A VM '$Client' já está a correr."
    } else {
        $startGb = [int][math]::Ceiling([double]$existing.MemoryStartup / 1GB)
        Write-Host "##PASSO:5"
        Stop-IfMemoryIsLow -StartupGb $startGb -AlreadyCreated $Client
        Write-Host "A iniciar a VM '$Client'..."
        Start-VM -Name $Client
    }
    Start-Process vmconnect.exe -ArgumentList "localhost", $Client
    Write-Host "A VM '$Client' está a arrancar."
    exit 0
}

# Linhas "##..." são lidas pela aplicação para mostrar o progresso e saber o que limpar se for cancelado.
Write-Host "##PASSO:1"

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

$computerName = Get-SafeComputerName $Client $UserName
$disk = Join-Path $Path "$Client.vhdx"
if (-not $IsoPath) {
    $IsoPath = Join-Path $Path "Win10_22H2_pt-PT_x64.iso"
}
if (Test-Path $disk) { throw "O disco já existe: $disk" }

$needsDownload = -not ((Test-Path -LiteralPath $IsoPath) -and ((Get-Item -LiteralPath $IsoPath).Length -gt 4GB))
Stop-IfDiskIsLow -VmFolder $Path -Iso $IsoPath -NeedsDownload $needsDownload -DiskSizeGb $DiskSize

Write-Host "##ISO:$IsoPath"
Get-MicrosoftIso -Destination $IsoPath -FidoLanguage $Language
Confirm-IsoHash -Iso $IsoPath -Expected $IsoSha256 -Downloaded $script:IsoWasDownloaded

Write-Host "##PASSO:2"
Write-Host "A criar o disco de '$Client'..."
New-VHD -Path $disk -Dynamic -SizeBytes ($DiskSize * 1GB) | Out-Null
Write-Host "##DISCO:$disk"
$xml = Get-UnattendXml -ComputerName $computerName -Account $UserName -AccountPassword $Password
try {
    Write-Host "##PASSO:3"
    Install-WindowsOffline -DiskPath $disk -Iso $IsoPath -VmGeneration $Generation -EditionName $ImageName -UnattendXml $xml
    Wait-VhdReleased $disk

    Write-Host "##PASSO:4"
    Write-Host "A criar a VM '$Client'..."
    New-VM -Name $Client -MemoryStartupBytes ($StartMem * 1GB) -VHDPath $disk -SwitchName $VSwitch -Generation $Generation | Out-Null
    Write-Host "##VM:$Client"
    Set-VMMemory -VMName $Client -DynamicMemoryEnabled $true -MinimumBytes ($StartMem * 1GB) -StartupBytes ($StartMem * 1GB) -MaximumBytes ($MaxMem * 1GB)
    Set-VMProcessor -VMName $Client -Count $Processors
    if ($Generation -eq 2) {
        Set-VMFirmware -VMName $Client -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    }
    if ((Get-Command Set-VM).Parameters.ContainsKey("AutomaticCheckpointsEnabled")) {
        Set-VM -Name $Client -AutomaticCheckpointsEnabled $false
    }

    Write-Host "##PASSO:5"
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
