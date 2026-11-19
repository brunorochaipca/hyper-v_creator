using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace CriarVmWindows;

public abstract record RunnerEvent;

/// <summary>Uma linha de texto para o registo.</summary>
public sealed record LogEvent(string Line) : RunnerEvent;

/// <summary>O script passou para o passo indicado (1 a <see cref="VmRunner.StepCount"/>).</summary>
public sealed record StepEvent(int Step) : RunnerEvent;

/// <summary>Progresso da descarga do ISO.</summary>
public sealed record DownloadEvent(int Percent, long DoneMb, long TotalMb) : RunnerEvent;

/// <summary>Um problema previsto que o script explica em português (memória, espaço em disco, integridade do ISO).</summary>
public sealed record RunNotice(string Kind, string Message);

/// <summary>Texto curto a mostrar ao lado do passo atual (por exemplo "A verificar o ISO...").</summary>
public sealed record DetailEvent(string Text) : RunnerEvent;

public sealed record RunResult(int ExitCode, RunNotice? Notice, bool Cancelled);

public sealed record HyperVStatus(bool Available, IReadOnlyList<string> Switches, string? Error);

/// <summary>Corre o win10vm.ps1 e traduz o que ele escreve em eventos para a interface.</summary>
public sealed class VmRunner
{
    public const int StepCount = 5;

    private const string RunCommand = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        try {
          $splat = @{
            Client = $env:VM_CLIENT
            UserName = $env:VM_USER
            Password = $env:VM_PASSWORD
            ImageName = $env:VM_IMAGE
            StartMem = [int]$env:VM_START_MEM
            MaxMem = [int]$env:VM_MAX_MEM
            Processors = [int]$env:VM_CPUS
            DiskSize = [int]$env:VM_DISK_GB
            Generation = [int]$env:VM_GENERATION
          }
          if ($env:VM_ISO) { $splat.IsoPath = $env:VM_ISO }
          if ($env:VM_SWITCH) { $splat.VSwitch = $env:VM_SWITCH }
          if ($env:VM_PATH) { $splat.Path = $env:VM_PATH }
          if ($env:VM_ISO_SHA256) { $splat.IsoSha256 = $env:VM_ISO_SHA256 }
          & $env:VM_SCRIPT @splat *>&1 | ForEach-Object { $_.ToString() }
          exit 0
        } catch {
          $text = $_.Exception.Message
          if ([string]::IsNullOrWhiteSpace($text)) { $text = $_.ToString() }
          Write-Output $text
          if ($text -like '*MEMORIA:*') { exit 2 }
          if ($text -like '*ESPACO:*') { exit 3 }
          if ($text -like '*INTEGRIDADE:*') { exit 4 }
          exit 1
        }
        """;

    // Depois de cancelar remove só o que esta execução criou: VM, disco, descarga em curso e montagens.
    private const string CleanupCommand = """
        $ErrorActionPreference = 'SilentlyContinue'
        Get-BitsTransfer -AllUsers | Where-Object { $_.DisplayName -eq 'CriarVmWindows' } | Remove-BitsTransfer
        if ($env:VM_ISO) { Dismount-DiskImage -ImagePath $env:VM_ISO | Out-Null }
        if ($env:VM_CREATED_VM) {
          Stop-VM -Name $env:VM_CREATED_VM -TurnOff -Force
          Remove-VM -Name $env:VM_CREATED_VM -Force
        }
        if ($env:VM_DISK -and (Test-Path -LiteralPath $env:VM_DISK)) {
          Dismount-VHD -Path $env:VM_DISK
          Remove-Item -LiteralPath $env:VM_DISK -Force
        }
        """;

    private const string ProbeCommand = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        try {
          Import-Module Hyper-V
          Get-VMSwitch | ForEach-Object { 'SWITCH:' + $_.Name }
          exit 0
        } catch {
          Write-Output ('ERRO:' + $_.Exception.Message)
          exit 1
        }
        """;

    private const string EditionsCommand = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $mounted = $false
        try {
          $image = Mount-DiskImage -ImagePath $env:VM_ISO -PassThru
          $mounted = $true
          $letter = ($image | Get-Volume).DriveLetter
          if (-not $letter) { throw 'O ISO foi montado sem letra de unidade.' }
          $file = @('install.wim', 'install.esd') | ForEach-Object { "${letter}:\sources\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
          if (-not $file) { throw 'O ISO não contém sources\install.wim nem sources\install.esd.' }
          Get-WindowsImage -ImagePath $file | ForEach-Object { 'EDICAO:' + $_.ImageName }
          exit 0
        } catch {
          Write-Output ('ERRO:' + $_.Exception.Message)
          exit 1
        } finally {
          if ($mounted) { Dismount-DiskImage -ImagePath $env:VM_ISO | Out-Null }
        }
        """;

    public async Task<RunResult> RunAsync(VmOptions options, IProgress<RunnerEvent> progress, CancellationToken cancel)
    {
        var script = FindScript()
            ?? throw new FileNotFoundException("Não encontrei win10vm.ps1 ao lado da aplicação nem nas pastas acima.");

        var env = new Dictionary<string, string>
        {
            ["VM_SCRIPT"] = script,
            ["VM_CLIENT"] = options.Name,
            ["VM_USER"] = options.UserName,
            ["VM_PASSWORD"] = options.Password,
            ["VM_IMAGE"] = options.Edition,
            ["VM_ISO"] = options.IsoPath ?? "",
            ["VM_START_MEM"] = options.StartMemGb.ToString(CultureInfo.InvariantCulture),
            ["VM_MAX_MEM"] = options.MaxMemGb.ToString(CultureInfo.InvariantCulture),
            ["VM_CPUS"] = options.Processors.ToString(CultureInfo.InvariantCulture),
            ["VM_DISK_GB"] = options.DiskGb.ToString(CultureInfo.InvariantCulture),
            ["VM_GENERATION"] = options.Generation.ToString(CultureInfo.InvariantCulture),
            ["VM_SWITCH"] = options.SwitchName ?? "",
            ["VM_PATH"] = options.Folder ?? "",
            ["VM_ISO_SHA256"] = options.IsoSha256 ?? ""
        };

        string? isoSeen = null, diskSeen = null, vmSeen = null;
        var lines = new List<string>();

        void OnLine(string line)
        {
            lock (lines)
                lines.Add(line);

            if (!line.StartsWith("##", StringComparison.Ordinal))
            {
                progress.Report(new LogEvent(line));
                return;
            }

            var colon = line.IndexOf(':');
            if (colon < 0)
                return;
            var kind = line[2..colon];
            var value = line[(colon + 1)..];
            switch (kind)
            {
                case "PASSO" when int.TryParse(value, CultureInfo.InvariantCulture, out var step):
                    progress.Report(new StepEvent(step));
                    break;
                case "DESCARGA":
                    var parts = value.Split('|');
                    if (parts.Length == 3
                        && int.TryParse(parts[0], CultureInfo.InvariantCulture, out var percent)
                        && long.TryParse(parts[1], CultureInfo.InvariantCulture, out var done)
                        && long.TryParse(parts[2], CultureInfo.InvariantCulture, out var total))
                        progress.Report(new DownloadEvent(percent, done, total));
                    break;
                case "DETALHE":
                    progress.Report(new DetailEvent(value));
                    break;
                case "ISO":
                    isoSeen = value;
                    break;
                case "DISCO":
                    diskSeen = value;
                    break;
                case "VM":
                    vmSeen = value;
                    break;
            }
        }

        using var process = CreateProcess(RunCommand, env);
        using var registration = cancel.Register(() => KillTree(process));
        var exitCode = await RunToEndAsync(process, OnLine);

        if (cancel.IsCancellationRequested)
        {
            progress.Report(new LogEvent("Cancelado. A limpar o que foi criado..."));
            await CleanupAsync(isoSeen, diskSeen, vmSeen);
            return new RunResult(exitCode, null, true);
        }

        RunNotice? notice = null;
        lock (lines)
        {
            foreach (var kind in new[] { "MEMORIA", "ESPACO", "INTEGRIDADE" })
            {
                var tag = kind + ":";
                var message = lines
                    .Select(line => line.Contains(tag, StringComparison.Ordinal)
                        ? line[(line.IndexOf(tag, StringComparison.Ordinal) + tag.Length)..].Trim()
                        : null)
                    .FirstOrDefault(text => !string.IsNullOrWhiteSpace(text));
                if (message is not null)
                {
                    notice = new RunNotice(kind, message);
                    break;
                }
            }
        }
        return new RunResult(exitCode, notice, false);
    }

    /// <summary>Verifica se o Hyper-V responde e devolve os comutadores virtuais.</summary>
    public static async Task<HyperVStatus> ProbeHyperVAsync()
    {
        var output = new List<string>();
        try
        {
            using var process = CreateProcess(ProbeCommand, new Dictionary<string, string>());
            var exit = await RunToEndAsync(process, output.Add);
            var error = output.FirstOrDefault(l => l.StartsWith("ERRO:", StringComparison.Ordinal))?[5..].Trim();
            var switches = output.Where(l => l.StartsWith("SWITCH:", StringComparison.Ordinal)).Select(l => l[7..].Trim()).ToList();
            return exit == 0 ? new HyperVStatus(true, switches, null) : new HyperVStatus(false, [], error ?? "O módulo Hyper-V não respondeu.");
        }
        catch (Exception ex)
        {
            return new HyperVStatus(false, [], ex.Message);
        }
    }

    /// <summary>Lê as edições que o ISO contém.</summary>
    public static async Task<(IReadOnlyList<string> Editions, string? Error)> ListEditionsAsync(string isoPath)
    {
        var output = new List<string>();
        try
        {
            using var process = CreateProcess(EditionsCommand, new Dictionary<string, string> { ["VM_ISO"] = isoPath });
            var exit = await RunToEndAsync(process, output.Add);
            var editions = output.Where(l => l.StartsWith("EDICAO:", StringComparison.Ordinal)).Select(l => l[7..].Trim()).ToList();
            if (exit == 0 && editions.Count > 0)
                return (editions, null);
            var error = output.FirstOrDefault(l => l.StartsWith("ERRO:", StringComparison.Ordinal))?[5..].Trim();
            return ([], error ?? "Não consegui ler as edições do ISO.");
        }
        catch (Exception ex)
        {
            return ([], ex.Message);
        }
    }

    private static async Task CleanupAsync(string? iso, string? disk, string? vm)
    {
        var env = new Dictionary<string, string>
        {
            ["VM_ISO"] = iso ?? "",
            ["VM_DISK"] = disk ?? "",
            ["VM_CREATED_VM"] = vm ?? ""
        };
        try
        {
            using var process = CreateProcess(CleanupCommand, env);
            await RunToEndAsync(process, null);
        }
        catch
        {
            // Se a limpeza falhar o utilizador ainda pode apagar o disco à mão.
        }
    }

    private static string? FindScript()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "win10vm.ps1");
            if (File.Exists(candidate))
                return candidate;
            dir = dir.Parent;
        }
        return null;
    }

    private static Process CreateProcess(string command, IReadOnlyDictionary<string, string> env)
    {
        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-ExecutionPolicy");
        start.ArgumentList.Add("Bypass");
        start.ArgumentList.Add("-Command");
        start.ArgumentList.Add(command);
        foreach (var (key, value) in env)
            start.Environment[key] = value;
        return new Process { StartInfo = start, EnableRaisingEvents = true };
    }

    private static async Task<int> RunToEndAsync(Process process, Action<string>? onLine)
    {
        void Take(object _, DataReceivedEventArgs e)
        {
            if (e.Data is not null)
                onLine?.Invoke(e.Data);
        }

        process.OutputDataReceived += Take;
        process.ErrorDataReceived += Take;
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        process.WaitForExit(); // garante que as últimas linhas já foram entregues
        return process.ExitCode;
    }

    private static void KillTree(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Já terminou.
        }
    }
}
