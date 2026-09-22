using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Nexus.Core;

namespace Nexus.App;

public partial class RulesPage : UserControl
{
    AppState S => AppState.Shared;
    RuleCompileResult? compiled;

    static readonly string[] ExampleRules =
    [
        "If a PDF in Downloads contains 'invoice' → move to Finance/Invoices/{year}, tag invoice",
        "If a screenshot lands in Screenshots → move to Pictures/Screenshots/{year}-{month}",
        "When a download finishes and it's an installer → move to Downloads/Installers",
        "When drive 'Backup' is connected → sync Documents",
        "Every Sunday at 9am: generate weekly report",
        "If a file in Downloads is older than 60 days → archive old files",
    ];

    public RulesPage()
    {
        InitializeComponent();
        foreach (var ex in ExampleRules)
        {
            var b = new Button { Content = ex.Length > 58 ? ex[..58] + "…" : ex, Tag = ex, Style = (Style)FindResource("Ghost"), Foreground = (System.Windows.Media.Brush)FindResource("Accent"), FontSize = 12 };
            b.Click += (_, _) => { Sentence.Text = (string)b.Tag; Preview_Click(this, new RoutedEventArgs()); };
            Examples.Children.Add(b);
        }
        Loaded += (_, _) => Sentence.Focus();
    }

    void Sentence_Changed(object sender, TextChangedEventArgs e) { CreateBtn.IsEnabled = false; PreviewBox.Visibility = Visibility.Collapsed; }
    void Sentence_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { if (CreateBtn.IsEnabled) Create_Click(sender, e); else Preview_Click(sender, e); } }

    async void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(Sentence.Text)) return;
        compiled = await S.Engine.CompileRule(Sentence.Text);
        PreviewBox.Visibility = Visibility.Visible;
        PreviewName.Text = compiled.Rule != null ? "✓  " + compiled.Rule.Name : "✗  Couldn’t build a rule from that";
        PreviewLines.ItemsSource = compiled.Explanation.Select(x => "· " + x).Concat(compiled.Warnings.Select(w => "⚠ " + w)).ToList();
        CreateBtn.IsEnabled = compiled.Rule != null;
    }

    void Create_Click(object sender, RoutedEventArgs e)
    {
        if (compiled?.Rule is not { } rule) return;
        S.Engine.Store.SaveRule(rule);
        S.Engine.RestartWatcher();
        S.ShowToast($"Rule “{rule.Name}” is live");
        Sentence.Clear();
        compiled = null;
    }

    static RuleRow Row(object sender) => (RuleRow)((FrameworkElement)sender).Tag;

    async void Run_Click(object sender, RoutedEventArgs e) => S.ShowToast(await S.Engine.RunRuleNow(Row(sender).Rule));

    void Test_Click(object sender, RoutedEventArgs e)
    {
        var rule = Row(sender).Rule;
        var folder = rule.Trigger.Folders.FirstOrDefault() ?? Paths.Expand("~/Downloads");
        var results = S.Engine.TestRule(rule, folder, 200);
        var hits = results.Where(r => r.eval.Fired).ToList();
        var lines = hits.Take(12).Select(h => $"✓ {h.file.Name} → {string.Join(", ", h.eval.PlannedActions)}")
            .Concat(results.Where(r => !r.eval.Fired).Take(6).Select(r => $"✗ {r.file.Name}: " + string.Join("; ", r.eval.ConditionResults.Where(c => !c.Passed).Select(c => $"{c.Condition.Summary} (was “{c.Actual}”)"))));
        MessageBox.Show(Window.GetWindow(this)!, $"Dry run on {Paths.Abbreviate(folder)} — {hits.Count} of {results.Count} files would match.\nNothing was changed.\n\n" + string.Join("\n", lines), "Rule simulator", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        var r = Row(sender).Rule;
        if (MessageBox.Show(Window.GetWindow(this)!, $"Delete “{r.Name}”?", "Delete rule", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            S.Engine.Store.DeleteRule(r.Id);
    }
}
