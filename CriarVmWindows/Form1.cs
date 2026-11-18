using System.Diagnostics;
using System.Text;

namespace CriarVmWindows;

public sealed class Form1 : Form
{
    private readonly RadioButton _downloadRadio = new() { Text = "Descarregar o Windows 10 22H2 em português", AutoSize = true, Checked = true };
    private readonly RadioButton _fileRadio = new() { Text = "Usar um ISO que já tenho", AutoSize = true };
    private readonly TextBox _isoPath = new() { Anchor = AnchorStyles.Left | AnchorStyles.Right };
    private readonly Button _browse = new() { Text = "Procurar...", AutoSize = true };
    private readonly TextBox _edition = new() { Text = "Windows 10 Pro" };
    private readonly TextBox _vmName = new() { Text = "LABWIN10" };
    private readonly TextBox _userName = new() { Text = "Lab" };
    private readonly TextBox _password = new() { Text = "Lab12345", UseSystemPasswordChar = true };
    private readonly CheckBox _showPassword = new() { Text = "Mostrar", AutoSize = true };
    private readonly Button _create = new() { Text = "Criar a VM", AutoSize = true };
    private readonly TextBox _log = new()
    {
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
        Font = new Font("Consolas", 9f),
        Dock = DockStyle.Fill
    };

    private bool _running;

    public Form1()
    {
        Text = "Criar VM Windows 10";
        Font = new Font("Segoe UI", 9f);
        ClientSize = new Size(680, 620);
        MinimumSize = new Size(560, 520);
        StartPosition = FormStartPosition.CenterScreen;

        _downloadRadio.CheckedChanged += (_, _) => UpdateIsoChoice();
        _fileRadio.CheckedChanged += (_, _) => UpdateIsoChoice();
        _browse.Click += (_, _) => BrowseIso();
        _showPassword.CheckedChanged += (_, _) => _password.UseSystemPasswordChar = !_showPassword.Checked;
        _create.Click += async (_, _) => await CreateVmAsync();

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(12) };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 186));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 140));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        _downloadRadio.Height = 24;
        _fileRadio.Height = 24;
        var isoFile = new TableLayoutPanel { Dock = DockStyle.Fill, Height = 28, ColumnCount = 2 };
        isoFile.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        isoFile.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _isoPath.Dock = DockStyle.Fill;
        isoFile.Controls.Add(_isoPath, 0, 0);
        isoFile.Controls.Add(_browse, 1, 0);

        var isoStack = Stack(
            _downloadRadio,
            _fileRadio,
            isoFile,
            Field("Edição dentro do ISO", _edition));
        var accountStack = Stack(
            Field("Utilizador", _userName),
            Field("Palavra-passe", PasswordRow()));

        root.Controls.Add(Box("ISO", isoStack), 0, 0);
        root.Controls.Add(Box("Máquina virtual", Field("Nome", _vmName)), 0, 1);
        root.Controls.Add(Box("Conta local", accountStack), 0, 2);
        root.Controls.Add(_create, 0, 3);
        root.Controls.Add(_log, 0, 4);
        Controls.Add(root);

        UpdateIsoChoice();
    }

    private Control PasswordRow()
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Height = 28 };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _password.Dock = DockStyle.Fill;
        row.Controls.Add(_password, 0, 0);
        row.Controls.Add(_showPassword, 1, 0);
        return row;
    }

    private static Control Field(string caption, Control input)
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Top, Height = 46, ColumnCount = 1, RowCount = 2 };
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
        panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        panel.Controls.Add(new Label { Text = caption, Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft }, 0, 0);
        input.Dock = DockStyle.Fill;
        panel.Controls.Add(input, 0, 1);
        return panel;
    }

    private static Control Stack(params Control[] rows)
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = rows.Length };
        for (var i = 0; i < rows.Length; i++)
        {
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, Math.Max(rows[i].Height, 24)));
            rows[i].Dock = DockStyle.Fill;
            rows[i].Margin = new Padding(0, 2, 0, 2);
            panel.Controls.Add(rows[i], 0, i);
        }
        return panel;
    }

    private static Control Box(string title, Control content)
    {
        var box = new GroupBox { Text = title, Dock = DockStyle.Fill, Padding = new Padding(10, 6, 10, 8) };
        content.Dock = DockStyle.Fill;
        box.Controls.Add(content);
        return box;
    }

    private void UpdateIsoChoice()
    {
        var chooseFile = _fileRadio.Checked;
        _isoPath.Enabled = chooseFile;
        _browse.Enabled = chooseFile;
    }

    private void BrowseIso()
    {
        using var dialog = new OpenFileDialog
        {
            Filter = "Imagem ISO (*.iso)|*.iso",
            Title = "Escolher o ISO do Windows"
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
            _isoPath.Text = dialog.FileName;
    }

    private async Task CreateVmAsync()
    {
        if (_running)
            return;

        var vmName = _vmName.Text.Trim();
        var user = _userName.Text.Trim();
        var password = _password.Text;
        var edition = _edition.Text.Trim();
        var download = _downloadRadio.Checked;
        var iso = _isoPath.Text.Trim();

        if (vmName.Length == 0 || vmName.Any(ch => !(char.IsLetterOrDigit(ch) || ch is ' ' or '-' or '_')))
        {
            Report("O nome da VM só pode ter letras, números, espaços, hífenes e sublinhados.");
            return;
        }
        if (user.Length == 0)
        {
            Report("Indica o nome da conta.");
            return;
        }
        if (password.Length == 0)
        {
            Report("Indica a palavra-passe.");
            return;
        }
        if (edition.Length == 0)
        {
            Report("Indica a edição, por exemplo Windows 10 Pro.");
            return;
        }
        if (!download && !File.Exists(iso))
        {
            Report("Escolhe um ficheiro ISO que exista.");
            return;
        }

        var script = FindScript();
        if (script is null)
        {
            Report("Não encontrei win10vm.ps1 ao lado da aplicação nem nas pastas acima.");
            return;
        }

        _running = true;
        _create.Enabled = false;
        _log.Clear();
        Append("A criar a VM. A cópia do Windows demora vários minutos.");

        try
        {
            var exit = await RunScriptAsync(script, vmName, user, password, edition, download ? "" : iso);
            Append(exit == 0
                ? "Concluído. A VM está a arrancar e entra sozinha com a conta indicada."
                : "A criação falhou.");
        }
        catch (Exception ex)
        {
            Append(ex.Message);
        }
        finally
        {
            _running = false;
            _create.Enabled = true;
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

    private static async Task<int> RunScriptAsync(string script, string vmName, string user, string password, string edition, string iso)
    {
        var command = """
            $ErrorActionPreference = 'Stop'
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $OutputEncoding = [Console]::OutputEncoding
            try {
              $splat = @{
                Client = $env:VM_CLIENT
                UserName = $env:VM_USER
                Password = $env:VM_PASSWORD
                ImageName = $env:VM_IMAGE
              }
              if ($env:VM_ISO) { $splat.IsoPath = $env:VM_ISO }
              & $env:VM_SCRIPT @splat *>&1 | ForEach-Object { $_.ToString() }
              exit 0
            } catch {
              Write-Output $_.ToString()
              exit 1
            }
            """;

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
        start.Environment["VM_SCRIPT"] = script;
        start.Environment["VM_CLIENT"] = vmName;
        start.Environment["VM_USER"] = user;
        start.Environment["VM_PASSWORD"] = password;
        start.Environment["VM_IMAGE"] = edition;
        start.Environment["VM_ISO"] = iso;

        using var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) AppendStatic(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendStatic(e.Data); };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private void Report(string message)
    {
        MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void Append(string line)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => Append(line));
            return;
        }
        _log.AppendText(line + Environment.NewLine);
    }

    private static void AppendStatic(string line)
    {
        var form = Application.OpenForms.OfType<Form1>().FirstOrDefault();
        form?.Append(line);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_running)
        {
            e.Cancel = true;
            Report("A criação ainda está a correr.");
        }
        base.OnFormClosing(e);
    }
}
