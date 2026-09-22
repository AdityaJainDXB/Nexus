using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Nexus.Core;

namespace Nexus.App;

/// Shown exactly once, on first launch. Closing it (any way) marks it as seen.
public partial class OnboardingWindow : Window
{
    AppState S => AppState.Shared;
    int step;
    readonly List<(CheckBox box, string path)> folderChoices = [];
    readonly List<(CheckBox box, string rule)> starterChoices = [];

    static readonly (string title, string rule, bool on)[] Starters =
    [
        ("File invoices and receipts into Finance", "If a PDF in Downloads contains 'invoice' or 'receipt' → move to Finance/{docType}/{year}, tag finance", true),
        ("Sort screenshots by month", "If a screenshot lands in Screenshots → move to Pictures/Screenshots/{year}-{month}", true),
        ("Put installers aside", "When a download finishes and it's an installer → move to Downloads/Installers", true),
        ("Weekly report every Sunday at 9 AM", "Every Sunday at 9am: generate weekly report", false),
        ("Back up Documents when drive “Backup” is plugged in", "When drive 'Backup' is connected → sync Documents", false),
    ];

    public OnboardingWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => DarkChrome.Apply(this);
        Show(0);
    }

    TextBlock T(string text, double size = 13.5, bool bold = false, string? brush = null)
    {
        var t = new TextBlock { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, Margin = new Thickness(0, 0, 0, 8) };
        if (brush != null) t.SetResourceReference(TextBlock.ForegroundProperty, brush);
        if (size > 20) t.FontFamily = (FontFamily)FindResource("DisplayFont");
        return t;
    }

    void Show(int i)
    {
        step = i;
        Back.Visibility = i == 0 ? Visibility.Hidden : Visibility.Visible;
        Next.Content = i == 3 ? "Start Nexus" : "Continue";
        StepLabel.Text = $"SETUP // {i + 1} OF 4";
        var panel = new StackPanel();
        switch (i)
        {
            case 0:
                panel.Children.Add(new Image { Source = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/logo.png")), Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 14) });
                panel.Children.Add(T("Meet Nexus — your PC files itself.", 28, true));
                panel.Children.Add(T("Nexus reads what’s inside your files, learns how you organize, files new downloads into your own folders, cleans up duplicates and runs automations you describe in plain English — all on this PC, with offline AI.", 14.5, false, "TextMuted"));
                panel.Children.Add(T($"•  Press {S.Settings.PaletteHotkey} anywhere to ask Nexus.\n•  Press {S.Settings.VoiceHotkey} and just say what you want.\n•  Every change can be undone. Nothing moves until you finish setup.", 14));
                break;
            case 1:
                panel.Children.Add(T("Where do you keep things?", 24, true));
                panel.Children.Add(T("Nexus found these folders. It learns their structure and files new downloads into them.", 13.5, false, "TextMuted"));
                if (folderChoices.Count == 0)
                    foreach (var c in FolderDiscovery.Candidates())
                        folderChoices.Add((new CheckBox { Style = (Style)FindResource("Switch"), IsChecked = c.Recommended || S.Settings.LibraryRootsExpanded.Contains(c.Path, Paths.Comparer), Margin = new Thickness(0, 6, 0, 6),
                            Content = new StackPanel { Children = { T($"{c.Label}  —  {Paths.Abbreviate(c.Path)}", 13.5, true), T(c.Subfolders.Count == 0 ? "empty" : string.Join(" · ", c.Subfolders.Take(6)) + (c.Subfolders.Count > 6 ? $" +{c.Subfolders.Count - 6}" : ""), 12, false, "TextMuted") } } }, c.Path));
                var list = new StackPanel();
                foreach (var (box, _) in folderChoices) { if (box.Parent is Panel p) p.Children.Remove(box); list.Children.Add(box); }
                panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 330, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
                break;
            case 2:
                panel.Children.Add(T("Start with a few automations", 24, true));
                panel.Children.Add(T("You can change or remove these anytime in Rules.", 13.5, false, "TextMuted"));
                if (starterChoices.Count == 0)
                    foreach (var (title, rule, on) in Starters)
                        starterChoices.Add((new CheckBox { Style = (Style)FindResource("Switch"), IsChecked = on, Margin = new Thickness(0, 7, 0, 7), Content = new StackPanel { Children = { T(title, 13.5, true), T(rule, 11.5, false, "TextFaint") } } }, rule));
                foreach (var (box, _) in starterChoices) { if (box.Parent is Panel p) p.Children.Remove(box); panel.Children.Add(box); }
                break;
            case 3:
                panel.Children.Add(T("You’re set.", 28, true));
                panel.Children.Add(T("Nexus lives in the system tray and the hotbar at the top of your screen. New files are filed when Nexus is confident; the rest wait in the Review Queue for one click.", 14.5, false, "TextMuted"));
                panel.Children.Add(T("Tip: pair your iPhone from “iPhone Remote” to control this PC from your phone.", 13.5, false, "Accent"));
                break;
        }
        Step.Content = panel;
    }

    void Back_Click(object sender, RoutedEventArgs e) => Show(Math.Max(0, step - 1));

    void Next_Click(object sender, RoutedEventArgs e)
    {
        if (step < 3) { Show(step + 1); return; }
        Finish();
        Close();
    }

    void Finish()
    {
        var s = S.Settings;
        var chosen = folderChoices.Where(f => f.box.IsChecked == true).Select(f => Paths.Abbreviate(f.path)).ToList();
        if (chosen.Count > 0) s.LibraryRoots = chosen;
        s.OnboardingComplete = true;
        S.SaveSettings(s);
        foreach (var (box, rule) in starterChoices.Where(x => x.box.IsChecked == true))
            if (new NLRuleCompiler(s.LibraryRoots.FirstOrDefault() ?? "~/Documents").Compile(rule).Rule is { } r) S.Engine.Store.SaveRule(r);
        S.Engine.RestartWatcher();
        S.Engine.Queue.Enqueue(new Job { Name = "Learn folder structure", Kind = JobKind.ai, Priority = JobPriority.high, Spec = new JobSpec { Operation = JobOperation.learnTaxonomy } });
        foreach (var root in s.LibraryRootsExpanded)
            S.Engine.Queue.Enqueue(new Job { Name = $"Index {Paths.Abbreviate(root)}", Kind = JobKind.ai, Priority = JobPriority.normal, Spec = new JobSpec { Operation = JobOperation.classifyFolder, Path = root } });
    }

    void Skip_Click(object sender, RoutedEventArgs e) => Close();
}
