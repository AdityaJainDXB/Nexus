using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Shapes;
using Nexus.Core;

namespace Nexus.App;

/// A slim HUD pinned near the top of the desktop: live activity ticker, mic, palette, review count, pause.
public partial class Hotbar : Window
{
    static Hotbar? shared;

    public static void Apply(string mode)
    {
        if (App.Headless) return;
        if (mode == "hidden") { shared?.Hide(); return; }
        shared ??= new Hotbar();
        if (!shared.IsVisible) shared.Show();
    }

    public Hotbar()
    {
        InitializeComponent();
        DataContext = AppState.Shared;
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + 8;
        SourceInitialized += (_, _) =>
        {
            var h = new WindowInteropHelper(this).Handle;
            SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80 | 0x08000000); // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        };
        AppState.Shared.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Update);
        Update();
    }

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);

    void Update()
    {
        var s = AppState.Shared;
        ReviewBtn.Content = s.ReviewCount > 0 ? $"⇲ {s.ReviewCount}" : "";
        ReviewBtn.Visibility = s.ReviewCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PauseBtn.Content = s.Paused ? "▶" : "⏸";
        Dot.SetResourceReference(Shape.FillProperty, s.EngineStatus switch { EngineStatus.working => "Accent", EngineStatus.attention => "Warn", EngineStatus.paused => "TextFaint", _ => "Good" });
    }

    void Drag(object sender, MouseButtonEventArgs e) { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); }
    void Review_Click(object sender, RoutedEventArgs e) => App.ShowMain("review");
    void Voice_Click(object sender, RoutedEventArgs e) => Palette.ShowVoice();
    void Ask_Click(object sender, RoutedEventArgs e) => Palette.Toggle();
    void Pause_Click(object sender, RoutedEventArgs e) => AppState.Shared.Engine.SetPaused(!AppState.Shared.Engine.Paused);
}
