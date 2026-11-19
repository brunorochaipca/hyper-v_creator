using System.ComponentModel;

namespace CriarVmWindows;

public enum StepState
{
    Pending,
    Running,
    Done,
    Error
}

/// <summary>Um passo da criação, mostrado na lista de progresso.</summary>
public sealed class StepItem(string title) : INotifyPropertyChanged
{
    private StepState _state = StepState.Pending;
    private string _detail = "";

    public string Title { get; } = title;

    public StepState State
    {
        get => _state;
        set
        {
            if (_state == value)
                return;
            _state = value;
            Raise(nameof(State));
            Raise(nameof(IsPending));
            Raise(nameof(IsRunning));
            Raise(nameof(IsDone));
            Raise(nameof(IsError));
        }
    }

    public string Detail
    {
        get => _detail;
        set
        {
            if (_detail == value)
                return;
            _detail = value;
            Raise(nameof(Detail));
        }
    }

    public bool IsPending => _state == StepState.Pending;
    public bool IsRunning => _state == StepState.Running;
    public bool IsDone => _state == StepState.Done;
    public bool IsError => _state == StepState.Error;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
