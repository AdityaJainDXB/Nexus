using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Nexus.Core;

namespace Nexus.App;

public static class Converters
{
    public static readonly IValueConverter NonZero = new Fn(v => v is int i && i > 0 ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter NotEmpty = new Fn(v => v is string s && s.Length > 0 ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter True = new Fn(v => v is true ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter False = new Fn(v => v is true ? Visibility.Collapsed : Visibility.Visible);

    class Fn(Func<object?, object> f) : IValueConverter
    {
        public object Convert(object? value, Type t, object? p, CultureInfo c) => f(value);
        public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => Binding.DoNothing;
    }
}

public partial class MainWindow : Window
{
    readonly Dictionary<string, Func<UserControl>> pages = new()
    {
        ["today"] = () => new TodayPage(), ["review"] = () => new ReviewPage(), ["files"] = () => new FilesPage(), ["projects"] = () => new ProjectsPage(),
        ["rules"] = () => new RulesPage(), ["tasks"] = () => new TasksPage(), ["insights"] = () => new InsightsPage(), ["activity"] = () => new ActivityPage(),
        ["remote"] = () => new RemotePage(), ["settings"] = () => new SettingsPage(),
    };
    public string Current { get; private set; } = "today";

    public MainWindow()
    {
        InitializeComponent();
        DataContext = AppState.Shared;
        AskHint.Text = AppState.Shared.Settings.PaletteHotkey;
        Page.Content = pages["today"]();
        AppState.Shared.Navigate += p => Dispatcher.BeginInvoke(() => Navigate(p));
        AppState.Shared.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppState.EngineStatus)) UpdateDot(); };
        SourceInitialized += (_, _) => DarkChrome.Apply(this);
        SizeChanged += (_, _) => DrawGrid();
        PreviewKeyDown += OnKey;
        UpdateDot();
    }

    public void Navigate(string page)
    {
        var key = page.ToLowerInvariant() switch
        {
            "review queue" => "review", "schedule" => "tasks", "connectors" => "remote", "rules & automations" => "rules", var k => k
        };
        if (!pages.ContainsKey(key)) key = "today";
        foreach (var rb in Nav.Children.OfType<RadioButton>()) if ((string)rb.Tag == key) { rb.IsChecked = true; return; }
    }

    void Nav_Checked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string key } && Page != null)
        {
            Current = key;
            Page.Content = pages[key]();
        }
    }

    void Ask_Click(object sender, RoutedEventArgs e) => Palette.Toggle();

    void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control)
        {
            string[] order = ["today", "review", "files", "projects", "rules", "tasks", "insights", "activity", "remote"];
            if (e.Key >= Key.D1 && e.Key <= Key.D9) { Navigate(order[e.Key - Key.D1]); e.Handled = true; }
            if (e.Key == Key.K) { Palette.Toggle(); e.Handled = true; }
            if (e.Key == Key.OemComma) { Navigate("settings"); e.Handled = true; }
        }
    }

    void UpdateDot()
    {
        var key = AppState.Shared.EngineStatus switch { EngineStatus.working => "Accent", EngineStatus.attention => "Warn", EngineStatus.paused => "TextFaint", _ => "Good" };
        StatusDot.SetResourceReference(Shape.FillProperty, key);
    }

    /// Faint HUD grid behind the content.
    void DrawGrid()
    {
        Grid.Children.Clear();
        var brush = (Brush)FindResource("Line");
        for (double x = 0; x < ActualWidth; x += 48) Grid.Children.Add(new Line { X1 = x, X2 = x, Y1 = 0, Y2 = ActualHeight, Stroke = brush, StrokeThickness = 0.5 });
        for (double y = 0; y < ActualHeight; y += 48) Grid.Children.Add(new Line { X1 = 0, X2 = ActualWidth, Y1 = y, Y2 = y, Stroke = brush, StrokeThickness = 0.5 });
    }
}

/// Dark title bar + Mica on Windows 11.
public static class DarkChrome
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void Apply(Window w)
    {
        try
        {
            var hwnd = new WindowInteropHelper(w).Handle;
            var dark = ThemeManager.IsDark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            var round = 2; DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
        }
        catch { }
    }
}
