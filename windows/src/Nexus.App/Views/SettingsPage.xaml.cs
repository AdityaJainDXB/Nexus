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

    Border? updateCard;

    public SettingsPage()
    {
        InitializeComponent();
        Build();
        S.PropertyChanged += OnState;
        Unloaded += (_, _) => S.PropertyChanged -= OnState;
    }

    void OnState(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.UpdateState)) RenderUpdates();
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

    /// The update card: switch, state, and Update / Not now / Skip this version.
    void RenderUpdates()
    {
        if (updateCard == null) return;
        var box = P(updateCard);
        box.Children.Clear();
        var state = S.UpdateState;

        var auto = new CheckBox { Style = (Style)FindResource("Switch"), Content = "Check for updates automatically", IsChecked = Cfg.AutomaticUpdateChecks, Margin = new Thickness(0, 2, 0, 8) };
        auto.Checked += (_, _) => { Cfg.AutomaticUpdateChecks = true; Save(); RenderUpdates(); };
        auto.Unchecked += (_, _) => { Cfg.AutomaticUpdateChecks = false; Save(); RenderUpdates(); };
        box.Children.Add(auto);
        box.Children.Add(new TextBlock
        {
            Text = Cfg.AutomaticUpdateChecks
                ? "Nexus checks GitHub a few seconds after launch and every 6 hours. Nothing is ever installed without your OK."
                : "Automatic checks are off — Nexus will not contact GitHub. You can still check by hand below.",
            Style = (Style)FindResource("Muted"), TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, Margin = new Thickness(0, 0, 0, 10),
        });

        if (state.Release is { } r && state.Stage is UpdateStage.Available or UpdateStage.Downloading or UpdateStage.Verifying or UpdateStage.Ready or UpdateStage.Installing)
        {
            var panel = new StackPanel();
            panel.Children.Add(new TextBlock { Text = $"Nexus {r.Version} is available", FontWeight = FontWeights.SemiBold, FontSize = 15 });
            panel.Children.Add(new TextBlock
            {
                Text = $"You have {S.Updater.CurrentVersion} · published {r.PublishedAt.ToLocalTime():d MMM yyyy}{(r.SizeText.Length > 0 ? " · " + r.SizeText : "")}",
                Style = (Style)FindResource("Muted"), Margin = new Thickness(0, 2, 0, 8),
            });
            var notes = r.Highlights;
            if (notes.Count > 0)
                panel.Children.Add(new TextBlock { Text = string.Join("\n", notes), Style = (Style)FindResource("Muted"), TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, Margin = new Thickness(0, 0, 0, 10) });

            if (state.Stage is UpdateStage.Downloading or UpdateStage.Verifying)
            {
                panel.Children.Add(new ProgressBar { Height = 6, Value = state.Progress * 100, IsIndeterminate = state.Stage == UpdateStage.Verifying, Margin = new Thickness(0, 0, 0, 6) });
                panel.Children.Add(new TextBlock { Text = state.Stage == UpdateStage.Verifying ? "Checking the download…" : state.Message ?? "Downloading…", Style = (Style)FindResource("Muted") });
            }
            else
            {
                var buttons = new WrapPanel();
                if (state.Stage is UpdateStage.Ready)
                {
                    var install = new Button { Content = "Install and restart", Style = (Style)FindResource("Primary"), Margin = new Thickness(0, 0, 8, 0) };
                    install.Click += (_, _) =>
                    {
                        if (MessageBox.Show(Window.GetWindow(this)!, $"Install Nexus {r.Version} now? Nexus will close, update and reopen.", "Update Nexus", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
                        if (S.Updater.Install(state.InstallerPath!)) Application.Current.Shutdown();
                    };
                    buttons.Children.Add(install);
                }
                else if (state.Stage != UpdateStage.Installing)
                {
                    var download = new Button { Content = "Update now", Style = (Style)FindResource("Primary"), Margin = new Thickness(0, 0, 8, 0) };
                    download.Click += async (_, _) => await S.Updater.Download(r);
                    buttons.Children.Add(download);
                }
                var later = new Button { Content = "Not now", Margin = new Thickness(0, 0, 8, 0) };
                later.Click += (_, _) => { S.ShowToast("Reminder set — Nexus will mention it again later."); S.GoTo("today"); };
                buttons.Children.Add(later);
                var skip = new Button { Content = "Skip this version", Style = (Style)FindResource("Ghost") };
                skip.Click += (_, _) => { S.Updater.Skip(r.Version); S.ShowToast($"Skipping {r.Version} — you'll hear about the next one."); RenderUpdates(); };
                buttons.Children.Add(skip);
                var notesLink = new Button { Content = "Release notes", Style = (Style)FindResource("Ghost") };
                notesLink.Click += (_, _) => Platform.Current.Open(r.Url);
                buttons.Children.Add(notesLink);
                panel.Children.Add(buttons);
            }
            var card = new Border { Style = (Style)FindResource("Card"), Child = panel, Margin = new Thickness(0, 0, 0, 10) };
            card.SetResourceReference(Border.BorderBrushProperty, "Accent");
            box.Children.Add(card);
        }
        else
        {
            var line = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
            var check = new Button { Content = state.Stage == UpdateStage.Checking ? "Checking…" : "Check now", IsEnabled = state.Stage != UpdateStage.Checking };
            check.Click += async (_, _) =>
            {
                var found = await S.Updater.Check();
                if (found == null && S.UpdateState.Stage == UpdateStage.UpToDate) S.ShowToast($"Nexus {S.Updater.CurrentVersion} is the latest version.");
                RenderUpdates();
            };
            DockPanel.SetDock(check, Dock.Right);
            line.Children.Add(check);
            var text = state.Stage switch
            {
                UpdateStage.Failed => state.Message ?? "Couldn't check for updates",
                UpdateStage.UpToDate => $"Nexus {S.Updater.CurrentVersion} is up to date",
                _ => S.Updater.LastChecked is { } t ? $"Last checked {t.ToLocalTime():d MMM, HH:mm}" : "Not checked yet",
            };
            line.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("Muted") });
            box.Children.Add(line);
            if (S.Updater.SkippedVersion is { Length: > 0 } skipped)
            {
                var un = new Button { Content = $"Stop skipping {skipped}", Style = (Style)FindResource("Ghost"), HorizontalAlignment = HorizontalAlignment.Left };
                un.Click += (_, _) => { S.Updater.Unskip(); S.ShowToast($"{skipped} will be offered again."); RenderUpdates(); };
                box.Children.Add(un);
            }
        }
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
        updateCard = Card("Updates", $"Nexus {S.Updater.CurrentVersion}. New versions are published on GitHub; Nexus can tell you when one appears and install it for you.");
        RenderUpdates();

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

        var f1 = Card("Formula 1 module", "Live timing, race control and championship standings from public feeds (OpenF1 · Jolpica). Unofficial, no account needed.");
        Switch(f1, "Show the Formula 1 page", Cfg.F1Enabled, v => Cfg.F1Enabled = v);
        Switch(f1, "Tell me 15 minutes before a session, and the result after", Cfg.F1Notifications, v => Cfg.F1Notifications = v);
        var fav = new DockPanel { Margin = new Thickness(0, 5, 0, 5) };
        var favBox = new TextBox { Text = Cfg.F1Favourite, Width = 200, ToolTip = "Driver code or name, e.g. NOR" };
        favBox.LostFocus += (_, _) => { Cfg.F1Favourite = favBox.Text.Trim(); Save(); };
        DockPanel.SetDock(favBox, Dock.Right);
        fav.Children.Add(favBox);
        fav.Children.Add(new TextBlock { Text = "Favourite driver (highlighted in answers)", VerticalAlignment = VerticalAlignment.Center });
        P(f1).Children.Add(fav);

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
