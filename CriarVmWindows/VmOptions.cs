namespace CriarVmWindows;

/// <summary>Tudo o que o utilizador escolhe. <see cref="IsoPath"/> vazio significa descarregar o ISO.</summary>
public sealed record VmOptions(
    string Name,
    string UserName,
    string Password,
    string Edition,
    string? IsoPath,
    int StartMemGb,
    int MaxMemGb,
    int Processors,
    int DiskGb,
    int Generation,
    string? SwitchName,
    string? Folder,
    string? IsoSha256);
