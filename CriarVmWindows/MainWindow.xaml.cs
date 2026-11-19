using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using WinRT.Interop;

namespace CriarVmWindows;

public sealed partial class MainWindow : Window
{
    private static readonly string[] DownloadEditions =
    [
        "Windows 10 Pro",
        "Windows 10 Home",
        "Windows 10 Education",
        "Windows 10 Pro Education"
    ];

    private static readonly string[] StepTitles =
    [
        "Obter e verificar o ISO do Windows",
        "Criar o disco virtual",
        "Instalar o Windows no disco",
        "Configurar a VM",
        "Arrancar a VM"
    ];

    private readonly ObservableCollection<StepItem> _steps = [];
    private readonly StringBuilder _log = new();
    private readonly IntPtr _hwnd;

    private bool _ready;
    private bool _running;
    private bool _showingResult;
    private bool _lastSucceeded;
    private bool _closeAfterRun;
    private bool _closeDialogOpen;
    private bool _hyperVOk = true;
    private int _currentStep;
    private int _editionRequest;
    private string? _editionsFor;
    private string _lastVmName = "";
    private CancellationTokenSource? _cts;

    public MainWindow()
    {
        InitializeComponent();

        Title = "Criar VM Windows 10";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        _hwnd = WindowNative.GetWindowHandle(this);
        SetInitialSize();

        StepsList.ItemsSource = _steps;
        SetEditions(DownloadEditions);
        UpdateNameHint();

        AppWindow.Closing += AppWindow_Closing;
        Root.Loaded += async (_, _) => await InitializeHyperVAsync();

        _ready = true;
    }

    // ----- Janela -----

    private void SetInitialSize()
    {
        var scale = GetDpiForWindow(_hwnd) / 96.0;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var width = Math.Min((int)(820 * scale), work.Width);
        var height = Math.Min((int)(900 * scale), work.Height);
        AppWindow.MoveAndResize(new RectInt32(
            work.X + (work.Width - width) / 2,
            work.Y + (work.Height - height) / 2,
            width,
            height));
    }

    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!_running)
            return;

        args.Cancel = true;
        if (_closeDialogOpen)
            return;

        _closeDialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "A criação ainda está a correr",
                Content = "Se saíres agora, a criação é cancelada e o que já foi criado é removido.",
                PrimaryButtonText = "Cancelar e sair",
                CloseButtonText = "Continuar a criar",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                _closeAfterRun = true;
                _cts?.Cancel();
            }
        }
        finally
        {
            _closeDialogOpen = false;
        }
    }

    // ----- Hyper-V -----

    private async Task InitializeHyperVAsync()
    {
        var status = await VmRunner.ProbeHyperVAsync();
        if (!status.Available)
        {
            _hyperVOk = false;
            HyperVBar.Title = "O Hyper-V não está disponível";
            HyperVBar.Message = "Ativa o Hyper-V em «Ativar ou desativar funcionalidades do Windows», reinicia o computador e abre a aplicação outra vez."
                + (string.IsNullOrWhiteSpace(status.Error) ? "" : $"\n\nDetalhe: {status.Error}");
            HyperVBar.IsOpen = true;
            CreateButton.IsEnabled = false;
            return;
        }

        foreach (var name in status.Switches)
            SwitchBox.Items.Add(name);

        if (status.Switches.Count == 0)
        {
            HyperVBar.Title = "Não há comutadores virtuais";
            HyperVBar.Message = "Cria um comutador no Gestor do Hyper-V para a VM ter rede. Sem ele a criação não avança.";
            HyperVBar.IsOpen = true;
        }
    }

    // ----- Escolha do ISO e da edição -----

    private bool UsingOwnIso => IsoSourceRadio.SelectedIndex == 1;

    private void IsoSourceRadio_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready)
            return;

        IsoFilePanel.Visibility = UsingOwnIso ? Visibility.Visible : Visibility.Collapsed;
        ClearError(IsoError);
        if (!UsingOwnIso)
        {
            _editionRequest++;
            _editionsFor = null;
            EditionRing.IsActive = false;
            EditionRing.Visibility = Visibility.Collapsed;
            EditionHint.Visibility = Visibility.Collapsed;
            SetEditions(DownloadEditions);
        }
        else
        {
            _ = LoadEditionsAsync();
        }
    }

    private async void BrowseIsoButton_Click(object sender, RoutedEventArgs e)
    {
        var file = NativeDialogs.OpenFile(_hwnd, "Escolher o ISO do Windows",
            "Imagem ISO (*.iso)\0*.iso\0Todos os ficheiros\0*.*\0");
        if (file is null)
            return;
        IsoPathBox.Text = file;
        await LoadEditionsAsync();
    }

    private void IsoPathBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready)
            ClearError(IsoError);
    }

    private async void IsoPathBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_ready && UsingOwnIso)
            await LoadEditionsAsync();
    }

    private void SetEditions(IReadOnlyList<string> editions)
    {
        var previous = EditionBox.SelectedItem as string;
        EditionBox.ItemsSource = editions;
        EditionBox.SelectedItem = previous is not null && editions.Contains(previous)
            ? previous
            : editions.FirstOrDefault(name => name == "Windows 10 Pro") ?? editions.FirstOrDefault();
    }

    /// <summary>Lê do ISO as edições que ele realmente tem, para não haver erros de escrita.</summary>
    private async Task LoadEditionsAsync()
    {
        var path = IsoPathBox.Text.Trim();
        if (path.Length == 0 || !File.Exists(path))
        {
            EditionHint.Text = "Escolhe o ISO para ver as edições que ele contém.";
            EditionHint.Visibility = Visibility.Visible;
            return;
        }
        if (string.Equals(path, _editionsFor, StringComparison.OrdinalIgnoreCase) || _running)
            return;

        var request = ++_editionRequest;
        EditionRing.Visibility = Visibility.Visible;
        EditionRing.IsActive = true;
        EditionBox.IsEnabled = false;
        EditionHint.Text = "A ler as edições do ISO…";
        EditionHint.Visibility = Visibility.Visible;

        var (editions, error) = await VmRunner.ListEditionsAsync(path);
        if (request != _editionRequest)
            return;

        EditionRing.IsActive = false;
        EditionRing.Visibility = Visibility.Collapsed;
        EditionBox.IsEnabled = true;

        if (error is null)
        {
            _editionsFor = path;
            SetEditions(editions);
            EditionHint.Text = $"{editions.Count} edições encontradas no ISO.";
        }
        else
        {
            _editionsFor = null;
            SetEditions(DownloadEditions);
            EditionHint.Text = $"Não consegui ler o ISO ({error}). Usei a lista habitual.";
        }
    }

    // ----- Campos e validação -----

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_ready)
            return;
        ClearError(NameError);
        UpdateNameHint();
    }

    private void UpdateNameHint()
    {
        var computer = ComputerName(NameBox.Text.Trim());
        NameHint.Text = $"Nome do computador dentro do Windows: {computer} (máximo 15 caracteres, só letras, números e hífenes).";
    }

    /// <summary>Igual a Get-SafeComputerName do script.</summary>
    private static string ComputerName(string name)
    {
        var clean = new string(name.Where(ch => ch is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-').ToArray());
        if (clean.Length == 0)
            clean = "WIN10VM";
        return clean.Length > 15 ? clean[..15] : clean;
    }

    private void Field_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready)
            ClearError(UserError);
    }

    private void PasswordBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_ready)
            ClearError(PasswordError);
    }

    private void Field_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_ready)
            ClearError(EditionError);
    }

    private void Field_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_ready)
            ClearError(AdvancedError);
    }

    private static void ShowError(TextBlock target, string message)
    {
        target.Text = message;
        target.Visibility = Visibility.Visible;
    }

    private static void ClearError(TextBlock target)
    {
        target.Text = "";
        target.Visibility = Visibility.Collapsed;
    }

    private VmOptions? ReadAndValidate()
    {
        Control? firstInvalid = null;

        void Fail(TextBlock error, string message, Control control)
        {
            ShowError(error, message);
            firstInvalid ??= control;
        }

        foreach (var error in new[] { NameError, UserError, PasswordError, IsoError, EditionError, AdvancedError, HashError })
            ClearError(error);

        var name = NameBox.Text.Trim();
        var user = UserBox.Text.Trim();
        var password = PasswordBox.Password;
        var iso = IsoPathBox.Text.Trim();
        var edition = EditionBox.SelectedItem as string;

        if (name.Length == 0 || name.Any(ch => !(char.IsLetterOrDigit(ch) || ch is ' ' or '-' or '_')))
            Fail(NameError, "O nome só pode ter letras, números, espaços, hífenes e sublinhados.", NameBox);

        var invalidUserChars = "\"/\\[]:;|=,+*?<>";
        if (user.Length == 0)
            Fail(UserError, "Indica o nome da conta.", UserBox);
        else if (user.Length > 20 || user.Any(invalidUserChars.Contains) || user.EndsWith('.'))
            Fail(UserError, "O nome da conta tem no máximo 20 caracteres e não pode ter / \\ [ ] : ; | = , + * ? < > \" nem acabar em ponto.", UserBox);

        if (password.Length == 0)
            Fail(PasswordError, "Indica a palavra-passe.", PasswordBox);

        if (UsingOwnIso && !File.Exists(iso))
            Fail(IsoError, "Escolhe um ficheiro ISO que exista.", IsoPathBox);

        if (edition is null)
            Fail(EditionError, "Escolhe a edição do Windows.", EditionBox);

        var hash = HashBox.Text.Replace(" ", "").Replace("-", "").Trim();
        if (hash.Length > 0 && (hash.Length != 64 || !hash.All(Uri.IsHexDigit)))
        {
            Fail(HashError, "O SHA-256 tem 64 caracteres hexadecimais (0-9 e A-F).", HashBox);
            AdvancedExpander.IsExpanded = true;
        }

        var startMem = ReadInt(StartMemBox);
        var maxMem = ReadInt(MaxMemBox);
        var cpus = ReadInt(CpuBox);
        var disk = ReadInt(DiskBox);
        if (startMem is null || maxMem is null || cpus is null || disk is null)
        {
            Fail(AdvancedError, "Preenche a memória, os processadores e o tamanho do disco.", StartMemBox);
            AdvancedExpander.IsExpanded = true;
        }
        else if (maxMem < startMem)
        {
            Fail(AdvancedError, "A memória máxima não pode ser menor do que a inicial.", MaxMemBox);
            AdvancedExpander.IsExpanded = true;
        }

        if (firstInvalid is not null)
        {
            firstInvalid.Focus(FocusState.Programmatic);
            return null;
        }

        var switchName = SwitchBox.SelectedIndex > 0 ? SwitchBox.SelectedItem as string : null;
        var folder = FolderBox.Text.Trim();
        return new VmOptions(
            name,
            user,
            password,
            edition!,
            UsingOwnIso ? iso : null,
            startMem!.Value,
            maxMem!.Value,
            cpus!.Value,
            disk!.Value,
            GenerationBox.SelectedIndex == 0 ? 2 : 1,
            switchName,
            folder.Length == 0 ? null : folder,
            hash.Length == 0 ? null : hash.ToUpperInvariant());
    }

    private static int? ReadInt(NumberBox box) => double.IsNaN(box.Value) ? null : (int)Math.Round(box.Value);

    private void HashBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready)
            ClearError(HashError);
    }

    private void BrowseFolderButton_Click(object sender, RoutedEventArgs e)
    {
        var folder = NativeDialogs.PickFolder(_hwnd, "Escolher a pasta dos discos virtuais");
        if (folder is not null)
            FolderBox.Text = folder;
    }

    private void ResetFolderButton_Click(object sender, RoutedEventArgs e) => FolderBox.Text = "";

    // ----- Criação -----

    private async void CreateButton_Click(object sender, RoutedEventArgs e)
    {
        if (_running)
            return;

        // Depois de uma criação o formulário está escondido: o botão serve para voltar a ele.
        if (_showingResult)
        {
            SetFormVisible(true);
            return;
        }

        var options = ReadAndValidate();
        if (options is null)
            return;

        _lastVmName = options.Name;
        ShowSummary(options);
        SetFormVisible(false);
        PrepareProgress();
        SetRunning(true);

        _cts = new CancellationTokenSource();
        var progress = new Progress<RunnerEvent>(OnRunnerEvent);
        var runner = new VmRunner();
        RunResult? result = null;
        string? failure = null;
        try
        {
            result = await Task.Run(() => runner.RunAsync(options, progress, _cts.Token));
        }
        catch (Exception ex)
        {
            failure = ex.Message;
        }

        var cancelled = result?.Cancelled == true;
        _cts.Dispose();
        _cts = null;
        SetRunning(false);

        if (cancelled)
            ShowCancelled();
        else if (failure is not null)
            ShowFailure(failure);
        else if (result!.Notice is not null)
            ShowNotice(result.Notice);
        else if (result.ExitCode == 0)
            ShowSuccess(options);
        else
            ShowFailure(LastMeaningfulLine() ?? "A criação falhou.");

        if (_closeAfterRun)
            Close();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_running || _cts is null)
            return;
        CancelButton.IsEnabled = false;
        ProgressHint.Text = "A cancelar e a limpar o que foi criado…";
        _cts.Cancel();
    }

    /// <summary>
    /// Mostra o formulário ou, durante e depois da criação, só o resumo e o progresso,
    /// para tudo caber no ecrã sem deslocar a página.
    /// </summary>
    private void SetFormVisible(bool visible)
    {
        _showingResult = !visible;
        FormPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        IntroPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SummaryCard.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        if (visible)
        {
            ProgressCard.Visibility = Visibility.Collapsed;
            OpenVmButton.Visibility = Visibility.Collapsed;
            CreateButton.Content = "Criar a VM";
            CreateButton.IsEnabled = _hyperVOk;
            if (_lastSucceeded && string.Equals(NameBox.Text.Trim(), _lastVmName, StringComparison.Ordinal))
                NameBox.Text = NextName(_lastVmName);
            _lastSucceeded = false;
        }
    }

    private void ShowSummary(VmOptions options)
    {
        SummaryTitle.Text = $"{options.Name} · {options.Edition}";
        var source = options.IsoPath is null ? "ISO descarregado" : $"ISO: {Path.GetFileName(options.IsoPath)}";
        SummaryDetail.Text =
            $"Conta «{options.UserName}» · {options.StartMemGb} GB de memória (até {options.MaxMemGb} GB) · {options.Processors} processadores · " +
            $"disco de {options.DiskGb} GB · geração {options.Generation} · {source}";
    }

    private void SetRunning(bool running)
    {
        _running = running;
        CancelButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.IsEnabled = running;
        CreateButton.IsEnabled = !running && _hyperVOk;
        OpenVmButton.Visibility = Visibility.Collapsed;
        if (!running)
            TitleText.Text = "Criar VM Windows 10";
    }

    private void PrepareProgress()
    {
        _steps.Clear();
        foreach (var title in StepTitles)
            _steps.Add(new StepItem(title));
        _currentStep = 0;
        _log.Clear();
        LogText.Text = "";
        ResultBar.IsOpen = false;
        ProgressBar.IsIndeterminate = true;
        ProgressBar.Visibility = Visibility.Visible;
        ProgressHint.Text = "";
        ProgressCard.Visibility = Visibility.Visible;
        AppendLog("A criar a VM. A cópia do Windows demora vários minutos.");
        _steps[0].State = StepState.Running;
        _currentStep = 1;
        TitleText.Text = "A criar a VM… (passo 1 de 5)";
    }

    private void OnRunnerEvent(RunnerEvent runnerEvent)
    {
        switch (runnerEvent)
        {
            case LogEvent log:
                AppendLog(log.Line);
                break;

            case StepEvent step when step.Step >= 1 && step.Step <= _steps.Count:
                _currentStep = step.Step;
                for (var i = 0; i < _steps.Count; i++)
                {
                    if (i < step.Step - 1)
                    {
                        _steps[i].State = StepState.Done;
                        _steps[i].Detail = "";
                    }
                    else if (i == step.Step - 1)
                    {
                        _steps[i].State = StepState.Running;
                    }
                }
                ProgressBar.IsIndeterminate = true;
                ProgressHint.Text = step.Step switch
                {
                    3 => "A copiar o Windows para o disco. Demora vários minutos.",
                    5 => "A iniciar a VM…",
                    _ => ""
                };
                TitleText.Text = $"A criar a VM… (passo {step.Step} de {_steps.Count})";
                break;

            case DetailEvent detail when _currentStep >= 1 && _currentStep <= _steps.Count:
                _steps[_currentStep - 1].Detail = detail.Text;
                ProgressBar.IsIndeterminate = true;
                break;

            case DownloadEvent download when _currentStep == 1:
                _steps[0].Detail = $"{download.Percent}% · {download.DoneMb:N0} de {download.TotalMb:N0} MB";
                ProgressBar.IsIndeterminate = false;
                ProgressBar.Value = download.Percent;
                ProgressHint.Text = "O link da Microsoft expira ao fim de 24 horas.";
                break;
        }
    }

    private void ShowSuccess(VmOptions options)
    {
        foreach (var step in _steps)
        {
            step.State = StepState.Done;
            step.Detail = "";
        }
        ProgressBar.Visibility = Visibility.Collapsed;
        ProgressHint.Text = "";
        ShowResult(InfoBarSeverity.Success, "VM criada",
            $"«{options.Name}» está a arrancar e entra sozinha com a conta «{options.UserName}». A primeira sessão mostra «A preparar o Windows». O Windows não fica ativado.");
        OpenVmButton.Visibility = Visibility.Visible;
        CreateButton.Content = "Criar outra VM";
        _lastSucceeded = true;
        AppendLog("Concluído.");
    }

    /// <summary>LABWIN10 passa a LABWIN11, para a nova VM não chocar com a que acabou de ser criada.</summary>
    private static string NextName(string name)
    {
        var end = name.Length;
        var start = end;
        while (start > 0 && char.IsDigit(name[start - 1]))
            start--;
        if (start == end)
            return name + "2";
        var digits = name[start..end];
        var next = (long.Parse(digits, CultureInfo.InvariantCulture) + 1).ToString(CultureInfo.InvariantCulture);
        return name[..start] + next.PadLeft(digits.Length, '0');
    }

    private void ShowCancelled()
    {
        foreach (var step in _steps)
        {
            step.State = StepState.Pending;
            step.Detail = "";
        }
        ProgressBar.Visibility = Visibility.Collapsed;
        ProgressHint.Text = "";
        ShowResult(InfoBarSeverity.Informational, "Criação cancelada", "O que foi criado nesta execução foi removido.");
        CreateButton.Content = "Editar e tentar outra vez";
        AppendLog("Cancelado.");
    }

    /// <summary>Problemas previstos pelo script: explicados em português, sem parecerem uma falha inesperada.</summary>
    private void ShowNotice(RunNotice notice)
    {
        CreateButton.Content = "Editar e tentar outra vez";
        MarkCurrentStepFailed();
        var (severity, title) = notice.Kind switch
        {
            "ESPACO" => (InfoBarSeverity.Warning, "Não há espaço livre suficiente"),
            "INTEGRIDADE" => (InfoBarSeverity.Error, "A verificação de integridade falhou"),
            _ => (InfoBarSeverity.Warning, "Não há memória livre suficiente")
        };
        ShowResult(severity, title, notice.Message);
        AppendLog(notice.Message);
    }

    private void ShowFailure(string message)
    {
        CreateButton.Content = "Editar e tentar outra vez";
        MarkCurrentStepFailed();
        ShowResult(InfoBarSeverity.Error, "A criação falhou", message);
        LogExpander.IsExpanded = true;
        AppendLog("A criação falhou.");
    }

    private void MarkCurrentStepFailed()
    {
        if (_currentStep >= 1 && _currentStep <= _steps.Count)
        {
            _steps[_currentStep - 1].State = StepState.Error;
            _steps[_currentStep - 1].Detail = "";
        }
        ProgressBar.Visibility = Visibility.Collapsed;
        ProgressHint.Text = "";
    }

    private void ShowResult(InfoBarSeverity severity, string title, string message)
    {
        ResultBar.Severity = severity;
        ResultBar.Title = title;
        ResultBar.Message = message;
        ResultBar.IsOpen = true;
    }

    private string? LastMeaningfulLine()
    {
        return _log.ToString()
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .LastOrDefault(line => line.Length > 0);
    }

    // ----- Registo -----

    private void AppendLog(string line)
    {
        // A palavra-passe aparece no resumo final do script; não a mostrar no ecrã nem nos ficheiros guardados.
        if (line.StartsWith("Palavra-passe:", StringComparison.Ordinal))
            line = "Palavra-passe: ••••••••";

        _log.AppendLine(line);
        LogText.Text = _log.ToString();
        if (LogExpander.IsExpanded)
        {
            LogScroller.UpdateLayout();
            LogScroller.ChangeView(null, LogScroller.ScrollableHeight, null);
        }
    }

    private void CopyLogButton_Click(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(_log.ToString());
        Clipboard.SetContent(package);
    }

    private void SaveLogButton_Click(object sender, RoutedEventArgs e)
    {
        var file = NativeDialogs.SaveFile(_hwnd, "Guardar o registo", "Texto (*.txt)\0*.txt\0",
            $"criar-vm-{DateTime.Now:yyyyMMdd-HHmm}.txt");
        if (file is null)
            return;
        if (!Path.HasExtension(file))
            file += ".txt";
        File.WriteAllText(file, _log.ToString(), new UTF8Encoding(false));
    }

    private void OpenVmButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var start = new ProcessStartInfo("vmconnect.exe") { UseShellExecute = false };
            start.ArgumentList.Add("localhost");
            start.ArgumentList.Add(_lastVmName);
            Process.Start(start);
        }
        catch (Exception ex)
        {
            ShowResult(InfoBarSeverity.Warning, "Não consegui abrir a ligação", ex.Message);
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
