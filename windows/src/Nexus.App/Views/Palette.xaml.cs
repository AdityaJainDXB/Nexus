using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Nexus.Core;

namespace Nexus.App;

public record StepView(string Label, string Note, List<string> Preview);

public partial class Palette : Window
{
    static Palette? shared;
    AppState S => AppState.Shared;
    CommandPlan? plan;
    string? plannedText;
    bool fromVoice, awaitingVoiceConfirm;
    int historyIndex = -1;

    Palette()
    {
        InitializeComponent();
        Deactivated += (_, _) => { if (!Voice.Shared.Listening) Hide(); };
        Voice.Shared.Partial += t => Dispatcher.BeginInvoke(() => { if (!awaitingVoiceConfirm) { Input.Text = t; Input.CaretIndex = t.Length; } VoiceLine.Text = "● listening… " + t; });
        Voice.Shared.Final += t => Dispatcher.BeginInvoke(() => OnVoiceFinal(t));
        Voice.Shared.Error += m => Dispatcher.BeginInvoke(() => { SetListening(false); ShowResult(m); });
    }

    static Palette Instance => shared ??= new Palette();

    public static void Toggle()
    {
        if (Instance.IsVisible && Instance.IsActive) { Instance.Hide(); return; }
        Instance.Open(null);
    }

    public static void ShowWith(string text) { Instance.Open(text); _ = Instance.PlanNow(); }

    public static void ShowVoice()
    {
        Instance.Open("");
        Instance.StartListening();
    }

    void Open(string? text)
    {
        ExplorerSelection.Capture();
        var sel = ExplorerSelection.Current();
        ContextChip.Visibility = sel.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ContextText.Text = sel.Count == 1 ? $"This: {System.IO.Path.GetFileName(sel[0])}" : $"This: {sel.Count} selected items";
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + area.Height * 0.16;
        Reset();
        if (text != null) { Input.Text = text; Input.CaretIndex = text.Length; }
        Show(); Activate(); Input.Focus();
        if (text == null) ShowSuggestions();
    }

    void Reset()
    {
        plan = null; plannedText = null; awaitingVoiceConfirm = false; fromVoice = false; historyIndex = -1;
        Steps.ItemsSource = null; Result.Visibility = Visibility.Collapsed; RunBtn.Visibility = Visibility.Collapsed;
        VoiceLine.Visibility = Visibility.Collapsed; Suggestions.ItemsSource = null; Body.Visibility = Visibility.Collapsed;
    }

    void ShowSuggestions()
    {
        var items = S.RecentCommands.Take(4).Concat(["organize Downloads", "clean up duplicates", "file this", "brief me"]).Distinct().Take(6).ToList();
        Suggestions.ItemsSource = items;
        Body.Visibility = Visibility.Visible;
    }

    void Input_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (plannedText != null && Input.Text != plannedText) { plan = null; RunBtn.Visibility = Visibility.Collapsed; }
    }

    async void Input_KeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape: Voice.Shared.Stop(); Hide(); e.Handled = true; break;
            case Key.Enter when Keyboard.Modifiers == ModifierKeys.Control: e.Handled = true; await PlanNow(); if (plan != null) await RunPlan(); break;
            case Key.Enter: e.Handled = true; if (plan != null && plan.RequiresConfirmation && plannedText == Input.Text) await RunPlan(); else await PlanNow(); break;
            case Key.Up when S.RecentCommands.Count > 0:
                historyIndex = Math.Min(historyIndex + 1, S.RecentCommands.Count - 1);
                Input.Text = S.RecentCommands[historyIndex]; Input.CaretIndex = Input.Text.Length; e.Handled = true; break;
            case Key.Z when Keyboard.Modifiers == ModifierKeys.Control && Input.Text.Length == 0:
                ShowResult(S.Engine.UndoLast() is var n && n > 0 ? $"Undid {n} operation(s)" : "Nothing to undo"); e.Handled = true; break;
        }
    }

    async Task PlanNow()
    {
        var text = Input.Text.Trim();
        if (text.Length == 0) return;
        Suggestions.ItemsSource = null;
        Result.Visibility = Visibility.Collapsed;
        Hints.Text = "Thinking…";
        plan = await S.Engine.Plan(text);
        plannedText = Input.Text;
        Steps.ItemsSource = plan.Steps.Select(s => new StepView(s.Step.Intent.Label.ToUpperInvariant(), s.Note ?? "", s.Preview.Take(8).ToList())).ToList();
        Body.Visibility = Visibility.Visible;
        if (!plan.RequiresConfirmation) { await RunPlan(); return; }
        RunBtn.Visibility = Visibility.Visible;
        Hints.Text = "↵ run it · Esc cancel · nothing changes until you confirm";
        if (fromVoice)
        {
            var summary = string.Join(". ", plan.Steps.Select(s => s.Note).Where(n => !string.IsNullOrEmpty(n)));
            Voice.Shared.Speak(summary + ". Say run it, or cancel.");
            awaitingVoiceConfirm = true;
            await Task.Delay(Math.Min(6000, 900 + summary.Length * 55));
            if (IsVisible && awaitingVoiceConfirm) StartListening();
        }
    }

    async Task RunPlan()
    {
        if (plan == null) return;
        var p = plan; plan = null;
        RunBtn.Visibility = Visibility.Collapsed;
        Hints.Text = "Working…";
        var r = await S.Engine.Execute(p);
        ShowResult(r.Message + (r.Details.Count > 0 ? "\n" + string.Join("\n", r.Details.Take(4)) : ""));
        if (fromVoice || p.Steps.Any(s => s.Step.Intent is Intent.Ask or Intent.Briefing)) Voice.Shared.Speak(r.Message);
        if (r.Navigate != null) App.ShowMain(r.Navigate);
        Hints.Text = "Ctrl+Z undo · Esc close";
    }

    void ShowResult(string text)
    {
        Body.Visibility = Visibility.Visible;
        Result.Text = text;
        Result.Visibility = Visibility.Visible;
    }

    async void Run_Click(object sender, RoutedEventArgs e) => await RunPlan();
    async void Suggestion_Click(object sender, RoutedEventArgs e) { Input.Text = (string)((FrameworkElement)sender).DataContext; await PlanNow(); }

    void Mic_Click(object sender, RoutedEventArgs e) { if (Voice.Shared.Listening) { Voice.Shared.Stop(); SetListening(false); } else StartListening(); }

    void StartListening()
    {
        fromVoice = true;
        SetListening(true);
        Voice.Shared.Listen();
    }

    void SetListening(bool on)
    {
        MicGlyph.Text = on ? "◉" : "🎙";
        MicGlyph.SetResourceReference(ForegroundProperty, on ? "Bad" : "Text");
        VoiceLine.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        VoiceLine.Text = awaitingVoiceConfirm ? "● listening for “run it” or “cancel”…" : "● listening…";
        if (on) Body.Visibility = Visibility.Visible;
    }

    async void OnVoiceFinal(string text)
    {
        SetListening(false);
        var t = text.Trim().TrimEnd('.').ToLowerInvariant();
        if (awaitingVoiceConfirm)
        {
            awaitingVoiceConfirm = false;
            if (t is "run it" or "yes" or "do it" or "go" or "go ahead" or "confirm" or "ok" or "okay" or "run") { await RunPlan(); return; }
            if (t.Length > 0) ShowResult("Cancelled — nothing changed.");
            return;
        }
        if (t.Length == 0) { VoiceLine.Visibility = Visibility.Collapsed; return; }
        Input.Text = text;
        if (S.Settings.VoiceAutoSubmit) await PlanNow();
    }
}
