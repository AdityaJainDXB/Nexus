using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Nexus.Core;

namespace Nexus.App;

public record F1RowView(F1Row Row)
{
    public int Position => Row.Position;
    public string Name => $"{Row.Driver.Acronym}  {Row.Driver.FullName}";
    public string Team => Row.Driver.Team;
    public string Gap => Row.Gap;
    public string Interval => Row.Int;
    public string Last => Row.Last;
    public string Best => Row.Best;
    public string Tyre => Row.Tyre;
    public Brush TeamBrush => new SolidColorBrush(Row.Driver.Colour is { Length: 6 } c && int.TryParse(c, System.Globalization.NumberStyles.HexNumber, null, out var v)
        ? Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v) : Colors.Gray);
    public Brush TyreBrush => Row.Compound?.ToUpperInvariant() switch
    {
        "SOFT" => Brushes.IndianRed, "MEDIUM" => Brushes.Goldenrod, "HARD" => Brushes.Gainsboro,
        "INTERMEDIATE" => Brushes.MediumSeaGreen, "WET" => Brushes.CornflowerBlue, _ => Brushes.Gray
    };
}

public record F1MessageView(F1Message M)
{
    public string Time => M.Time;
    public string Text => M.Text;
    public Brush Brush => (M.Flag ?? "").ToUpperInvariant() switch
    {
        "RED" => Brushes.IndianRed, "YELLOW" or "DOUBLE YELLOW" => Brushes.Goldenrod, "GREEN" or "CLEAR" => Brushes.MediumSeaGreen,
        "CHEQUERED" => Brushes.White, "BLUE" => Brushes.CornflowerBlue, _ => (Brush)Application.Current.Resources["TextMuted"]
    };
}

public record StandingView(string Position, string Name, string Points);

public partial class F1Page : UserControl
{
    AppState S => AppState.Shared;
    DispatcherTimer? timer;
    bool showTeams;
    F1Race? next;

    public F1Page()
    {
        InitializeComponent();
        Loaded += async (_, _) => { await Refresh(); Start(); };
        Unloaded += (_, _) => timer?.Stop();
    }

    void Start()
    {
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        var tick = 0;
        timer.Tick += async (_, _) =>
        {
            Tick();                                   // countdown every second, data less often
            if (++tick % (live ? 5 : 60) == 0) await Refresh();
        };
        timer.Start();
    }

    bool live;

    void Tick()
    {
        if (next == null) return;
        var d = next.StartUtc - DateTime.UtcNow;
        Countdown.Text = d.TotalSeconds <= 0 ? "under way" : d.TotalDays >= 1 ? $"{(int)d.TotalDays}d {d.Hours:00}h {d.Minutes:00}m" : $"{(int)d.TotalHours:00}:{d.Minutes:00}:{d.Seconds:00}";
    }

    async void Refresh_Click(object sender, RoutedEventArgs e) => await Refresh();

    async Task Refresh()
    {
        try
        {
            var liveData = await S.Engine.F1.Live();
            next = await S.Engine.F1.NextRace();
            live = liveData?.Running == true;

            if (liveData != null)
            {
                Title.Text = liveData.Session.Title;
                StatusText.Text = liveData.Status;
                StatusChip.Background = liveData.Status switch
                {
                    "GREEN" => new SolidColorBrush(Color.FromArgb(40, 61, 245, 160)),
                    "RED" => new SolidColorBrush(Color.FromArgb(50, 255, 92, 122)),
                    "YELLOW" or "DOUBLE YELLOW" => new SolidColorBrush(Color.FromArgb(50, 255, 181, 71)),
                    _ => (Brush)Application.Current.Resources["AccentSoft"],
                };
                Subtitle.Text = string.Join("  ·  ", new[]
                {
                    liveData.Session.Type,
                    liveData.Lap is { } l ? $"lap {l}" : null,
                    live ? "live" : liveData.Session.StartUtc > DateTime.UtcNow ? $"starts {liveData.Session.StartLocal:ddd HH:mm}" : $"ended {liveData.Session.EndLocal:ddd HH:mm}",
                    liveData.Weather?.Summary,
                }.Where(x => !string.IsNullOrEmpty(x)));
                Board.ItemsSource = liveData.Rows.Select(r => new F1RowView(r)).ToList();
                Control.ItemsSource = liveData.Messages.Take(12).Select(m => new F1MessageView(m)).ToList();
                Empty.Visibility = liveData.Rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                HeaderRow.Visibility = liveData.Rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            }
            else
            {
                Title.Text = "Formula 1";
                StatusText.Text = S.Engine.F1.LastError == null ? "NO SESSION" : "OFFLINE";
                Subtitle.Text = S.Engine.F1.LastError == null ? "" : "Couldn't reach the timing feed — retrying.";
                Empty.Visibility = Visibility.Visible;
                HeaderRow.Visibility = Visibility.Collapsed;
            }

            if (next != null)
            {
                NextName.Text = next.Name;
                NextWhen.Text = $"{next.Circuit} · {next.Locality}, {next.Country}\nLights out {next.StartLocal:dddd d MMMM, HH:mm}";
                Sessions.ItemsSource = next.Sessions.Select(x => $"{x.startUtc.ToLocalTime():ddd HH:mm}  {x.name}").ToList();
                Tick();
            }
            NextCard.Visibility = next == null ? Visibility.Collapsed : Visibility.Visible;
            await LoadStandings();
            Updated.Text = $"updated {DateTime.Now:HH:mm:ss}";
        }
        catch (Exception ex) { Updated.Text = "update failed: " + ex.Message; }
    }

    async Task LoadStandings()
    {
        var list = showTeams ? await S.Engine.F1.ConstructorStandings() : await S.Engine.F1.DriverStandings();
        StandingsTitle.Text = showTeams ? "CONSTRUCTORS' CHAMPIONSHIP" : "DRIVERS' CHAMPIONSHIP";
        StandingsToggle.Content = showTeams ? "Drivers →" : "Teams →";
        Standings.ItemsSource = list.Take(12).Select(s => new StandingView(s.Position.ToString(), showTeams ? s.Name : $"{s.Code}  {s.Name}", $"{s.Points:0.#}")).ToList();
    }

    async void ToggleStandings_Click(object sender, RoutedEventArgs e) { showTeams = !showTeams; await LoadStandings(); }
}
