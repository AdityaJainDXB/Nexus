using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Nexus.Core;

namespace Nexus.App;

/// Settings are built in code: each control writes straight through to NexusSettings.
public partial class SettingsPage : UserControl
{
    AppState S => AppState.Shared;
    NexusSettings Cfg => S.Settings;

    public SettingsPage()
    {
        InitializeComponent();
        Build();
    }

    void Save() => S.SaveSettings(Cfg);

    Border Card(string title, string? subtitle = null)
    {
        Body.Children.Add(new TextBlock { Text = title.ToUpperInvariant(), Style = (Style)FindResource("Section") });
        var panel = new StackPanel();
        if (subtitle != null) panel.Children.Add(new TextBlock { Text = subtitle, Style = (Style)FindResource("Muted"), TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, Margin = new Thickness(0, 0, 0, 10) });
        var card = new Border { Style = (Style)FindResource("Card"), Child = panel };
        Body.Children.Add(card);
        return card;
    }

    static StackPanel P(Border b) => (StackPanel)b.Child;

    void Switch(Border card, string label, bool value, Action<bool> set)
    {
        var cb = new CheckBox { Style = (Style)FindResource("Switch"), Content = label, IsChecked = value, Margin = new Thickness(0, 5, 0, 5) };
        cb.Checked += (_, _) => { set(true); Save(); };
        cb.Unchecked += (_, _) => { set(false); Save(); };
        P(card).Children.Add(cb);
    }

    void Choice(Border card, string label, string[] options, string value, Action<string> set)
    {
        var row = new DockPanel { Margin = new Thickness(0, 5, 0, 5) };
        var combo = new ComboBox { ItemsSource = options, SelectedItem = options.Contains(value) ? value : options[0], MinWidth = 200 };
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is string s) { set(s); Save(); } };
        DockPanel.SetDock(combo, Dock.Right);
        row.Children.Add(combo);
        row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        P(card).Children.Add(row);
    }

    void Slider(Border card, string label, double min, double max, double value, Action<double> set, string format = "0%")
    {
        var row = new DockPanel { Margin = new Thickness(0, 5, 0, 5) };
        var readout = new TextBlock { Text = value.ToString(format), Width = 50, Style = (Style)FindResource("Mono"), VerticalAlignment = VerticalAlignment.Center };
        var slider = new System.Windows.Controls.Slider { Minimum = min, Maximum = max, Value = value, Width = 220, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, e) => { readout.Text = e.NewValue.ToString(format); set(Math.Round(e.NewValue, 2)); };
        slider.PreviewMouseUp += (_, _) => Save();
        DockPanel.SetDock(readout, Dock.Right); DockPanel.SetDock(slider, Dock.Right);
        row.Children.Add(readout); row.Children.Add(slider);
        row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        P(card).Children.Add(row);
    }

    void Folders(Border card, string label, List<string> list)
    {
        var box = new StackPanel();
        void Render()
        {
            box.Children.Clear();
            foreach (var f in list.ToList())
            {
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var remove = new Button { Content = "Remove", Style = (Style)FindResource("Ghost"), Foreground = (System.Windows.Media.Brush)FindResource("Bad") };
                remove.Click += (_, _) => { list.Remove(f); Save(); Render(); };
                DockPanel.SetDock(remove, Dock.Right);
                row.Children.Add(remove);
                row.Children.Add(new TextBlock { Text = f, Style = (Style)FindResource("Mono"), VerticalAlignment = VerticalAlignment.Center });
                box.Children.Add(row);
            }
            var add = new Button { Content = "+ Add folder…", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
            add.Click += (_, _) =>
            {
                var dlg = new OpenFolderDialog { Title = label };
                if (dlg.ShowDialog() == true) { list.Add(Paths.Abbreviate(dlg.FolderName)); Save(); Render(); }
            };
            box.Children.Add(add);
        }
        P(card).Children.Add(new TextBlock { Text = label, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 4) });
        P(card).Children.Add(box);
        Render();
    }

    void Build()
    {
        var folders = Card("Folders", "Watched folders are tidied automatically. Library folders are where Nexus learns your structure and files things.");
        Folders(folders, "Watch for new files", Cfg.WatchedFolders);
        Folders(folders, "Your library (filing destinations)", Cfg.LibraryRoots);
        var rediscover = new Button { Content = "Find my folders again", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        rediscover.Click += (_, _) =>
        {
            var found = FolderDiscovery.Candidates().Where(c => c.Recommended).Select(c => Paths.Abbreviate(c.Path)).ToList();
            foreach (var f in found.Where(f => !Cfg.LibraryRoots.Contains(f))) Cfg.LibraryRoots.Add(f);
            Save();
            S.Engine.Queue.Enqueue(new Job { Name = "Learn folder structure", Kind = JobKind.ai, Priority = JobPriority.high, Spec = new JobSpec { Operation = JobOperation.learnTaxonomy } });
            S.ShowToast($"Found {found.Count} places you keep things — learning them now");
            while (Body.Children.Count > 2) Body.Children.RemoveAt(2);
            Build();
        };
        P(folders).Children.Add(rediscover);

        var auto = Card("Autopilot", "Nexus files a new file only when it's confident; medium-confidence suggestions wait in the Review Queue. Every change can be undone.");
        Switch(auto, "File new downloads automatically", Cfg.AutopilotEnabled, v => Cfg.AutopilotEnabled = v);
        Slider(auto, "Confidence to file automatically", 0.6, 0.99, Cfg.AutoThreshold, v => Cfg.AutoThreshold = v);
        Slider(auto, "Confidence to suggest in Review", 0.3, 0.9, Cfg.ReviewThreshold, v => Cfg.ReviewThreshold = v);
        Switch(auto, "Remove re-downloaded duplicates (to the Recycle Bin)", Cfg.AutoRemoveDuplicates, v => Cfg.AutoRemoveDuplicates = v);
        Switch(auto, "Read text in images (Windows OCR)", Cfg.EnableOcr, v => Cfg.EnableOcr = v);
        Switch(auto, "Dry run — preview everything, change nothing", Cfg.DryRun, v => Cfg.DryRun = v);
        Switch(auto, "Slow down on battery and in Energy Saver", Cfg.BatteryAware, v => Cfg.BatteryAware = v);

        var ai = Card("On-device AI", "Nexus ships with a small offline model (Qwen 2.5, via llama.cpp). Nothing is sent to the cloud.");
        Choice(ai, "AI engine", ["auto", "bundled", "ollama", "off"], Cfg.LlmProvider.ToString(), v => Cfg.LlmProvider = Enum.Parse<LlmProvider>(v));
        P(ai).Children.Add(new TextBlock { Text = LocalModelServer.Shared.IsAvailable ? $"Bundled model: {LocalModelServer.Shared.ModelName} ✓" : "Bundled model not found — reinstall Nexus or choose Ollama.", Style = (Style)FindResource("Muted"), Margin = new Thickness(0, 6, 0, 0) });
        P(ai).Children.Add(new TextBlock { Text = "In use now: " + S.LlmName, Style = (Style)FindResource("Muted") });

        var voice = Card("Voice & shortcuts", Voice.Available ? "Hold or tap the voice shortcut anywhere, speak, and Nexus acts. Speech runs on this PC." : "Windows speech recognition isn't installed. Add an English speech pack in Settings → Time & language → Speech to use voice.");
        Choice(voice, "Command palette", Hotkeys.PaletteChoices, Cfg.PaletteHotkey, v => Cfg.PaletteHotkey = v);
        Choice(voice, "Talk to Nexus", Hotkeys.VoiceChoices, Cfg.VoiceHotkey, v => Cfg.VoiceHotkey = v);
        Switch(voice, "Run voice commands as soon as I stop talking", Cfg.VoiceAutoSubmit, v => Cfg.VoiceAutoSubmit = v);
        Switch(voice, "Speak answers out loud", Cfg.SpeakResponses, v => Cfg.SpeakResponses = v);

        var look = Card("Appearance & behaviour");
        Choice(look, "Theme", ["system", "dark", "light"], Cfg.Appearance, v => Cfg.Appearance = v);
        Choice(look, "Desktop hotbar", ["floating", "hidden"], Cfg.Hotbar, v => Cfg.Hotbar = v);
        Switch(look, "Start Nexus when I sign in", Cfg.LaunchAtLogin, v => Cfg.LaunchAtLogin = v);
        Switch(look, "Notifications", Cfg.NotificationsEnabled, v => Cfg.NotificationsEnabled = v);

        var adv = Card("Advanced");
        Switch(adv, "Allow rules to run PowerShell scripts", Cfg.AllowScripts, v => Cfg.AllowScripts = v);
        Switch(adv, "Local API for scripts & nexusctl (127.0.0.1 only)", Cfg.ApiEnabled, v => Cfg.ApiEnabled = v);
        var open = new Button { Content = "Open data folder", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        open.Click += (_, _) => Process.Start("explorer.exe", Paths.AppSupport);
        P(adv).Children.Add(open);
        var reset = new Button { Content = "Show welcome tour again", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        reset.Click += (_, _) => App.ShowOnboarding();
        P(adv).Children.Add(reset);
        Body.Children.Add(new TextBlock { Text = $"Nexus for Windows {typeof(App).Assembly.GetName().Version?.ToString(3)} · MIT · data in {Paths.AppSupport}", Style = (Style)FindResource("Muted"), Margin = new Thickness(2, 18, 0, 20) });
    }
}
