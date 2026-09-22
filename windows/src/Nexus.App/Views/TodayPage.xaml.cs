using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Nexus.App;

public partial class TodayPage : UserControl
{
    AppState S => AppState.Shared;

    public TodayPage()
    {
        InitializeComponent();
        var h = DateTime.Now.Hour;
        Greeting.Text = (h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening") + ". Here’s your PC today.";
        Eyebrow.Text = $"TODAY // {DateTime.Now:dddd, MMMM d}".ToUpperInvariant();
        Loaded += (_, _) => { Refresh(); S.PropertyChanged += Changed; Command.Focus(); };
        Unloaded += (_, _) => S.PropertyChanged -= Changed;
    }

    void Changed(object? s, System.ComponentModel.PropertyChangedEventArgs e) { if (e.PropertyName is nameof(AppState.ReviewCount) or nameof(AppState.InsightCount) or nameof(AppState.Ticker)) Refresh(); }

    void Refresh()
    {
        ReviewList.ItemsSource = S.Reviews.Take(4).ToList();
        InsightList.ItemsSource = S.Insights.Take(4).ToList();
        EventList.ItemsSource = S.Events.Take(9).ToList();
        NoReview.Visibility = S.Reviews.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoInsights.Visibility = S.Insights.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    async void Run(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var plan = await S.Engine.Plan(text);
        if (plan.RequiresConfirmation) { Palette.ShowWith(text); return; }   // changes get a preview first
        var r = await S.Engine.Execute(plan);
        S.ShowToast(r.Message);
        if (r.Navigate != null) S.GoTo(r.Navigate);
        Command.Clear();
    }

    void Run_Click(object sender, RoutedEventArgs e) => Run(Command.Text);
    void Command_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) Run(Command.Text); }
    void Mic_Click(object sender, RoutedEventArgs e) => Palette.ShowVoice();
    void Quick_Click(object sender, RoutedEventArgs e) => Run((string)((Button)sender).Tag);
    void OpenReview_Click(object sender, RoutedEventArgs e) => S.GoTo("review");
    async void Approve_Click(object sender, RoutedEventArgs e) { await S.Engine.Approve(((ReviewRow)((Button)sender).Tag).Item); S.ShowToast("Filed ✓"); }
    void Fix_Click(object sender, RoutedEventArgs e)
    {
        var i = ((InsightRow)((Button)sender).Tag).Item;
        if (i.Command != null) Palette.ShowWith(i.Command);
    }
}
