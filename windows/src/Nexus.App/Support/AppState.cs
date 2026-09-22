using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using Nexus.Core;

namespace Nexus.App;

public class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public record ReviewRow(ReviewItem Item)
{
    public string Name => System.IO.Path.GetFileName(Item.Path);
    public string From => Paths.Abbreviate(Paths.FolderOf(Item.Path));
    public string Destination => Item.SuggestedDestination is { } d ? Paths.Abbreviate(d) : "—";
    public string Confidence => $"{(int)(Item.Confidence * 100)}%";
    public string Reason => string.Join(" · ", Item.Reasons);
    public string Tags => Item.SuggestedTags.Count == 0 ? "" : string.Join("  ", Item.SuggestedTags.Select(t => "#" + t));
    public List<string> Alternatives => Item.Alternatives.Select(Paths.Abbreviate).ToList();
}

public record InsightRow(Insight Item)
{
    public string Title => Item.Title;
    public string Detail => Item.Detail;
    public string Severity => Item.Severity.ToString().ToUpperInvariant();
    public bool HasFix => !string.IsNullOrEmpty(Item.Command);
    public string FixLabel => Item.Kind switch { InsightKind.habit => "Create rule", InsightKind.conflicts => "Review rules", InsightKind.deadlineSoon => "Start focus", _ => "Fix it" };
}

public class RuleRow(Rule rule) : Observable
{
    public Rule Rule { get; } = rule;
    public string Name => Rule.Name;
    public string Summary => Rule.Summary;
    public string Hits => Rule.HitCount == 0 ? "never fired" : $"{Rule.HitCount} hits";
    public bool Enabled
    {
        get => Rule.Enabled;
        set { Rule.Enabled = value; AppState.Shared.Engine.Store.SaveRule(Rule); AppState.Shared.Engine.RestartWatcher(); Raise(); }
    }
}

public record EventRow(ActivityEvent Item)
{
    public string Time => Item.Timestamp.ToString(Item.Timestamp.Date == DateTime.Today ? "HH:mm" : "MMM d HH:mm");
    public string Message => Item.Message;
    public string Kind => Item.Kind.ToString();
    public bool Undoable => Item.Undo != null && !Item.Undone;
    public double Opacity => Item.Undone ? 0.45 : 1;
}

public record JobRow(Job Item)
{
    public string Name => Item.Name;
    public string Status => Item.Status.ToString();
    public string Detail => Item.Error ?? Item.ResultSummary ?? (Item.Status == JobStatus.scheduled ? $"at {Item.ScheduledFor:MMM d HH:mm}" : "");
    public string When => Item.CreatedAt.ToString("MMM d HH:mm");
    public bool CanRetry => Item.Status == JobStatus.failed;
}

public record ProjectRow(Project Item, int Files, long Bytes)
{
    public string Name => Item.Name;
    public string Stats => $"{Files} files · {Text.FormatBytes(Bytes)}" + (Item.Deadline is { } d ? $" · due {d:MMM d}" : "");
    public string Keywords => string.Join(", ", Item.Keywords);
    public string Color => Item.Color;
}

public record FileRow(FileRecord Item)
{
    public string Name => Item.Name;
    public string Folder => Paths.Abbreviate(Item.Folder);
    public string Meta => string.Join(" · ", new[] { Item.DocType, Item.Topics.Count > 0 ? string.Join(", ", Item.Topics.Take(3)) : null, Item.Tags.Count > 0 ? string.Join(" ", Item.Tags.Select(t => "#" + t)) : null }.Where(x => !string.IsNullOrEmpty(x)));
    public string Snippet => Item.Summary ?? Item.Snippet;
}

public record DeviceRow(RemoteServer.Device Item)
{
    public string Name => Item.Name;
    public string Seen => Item.LastSeen is { } s ? "last seen " + Nexus.Core.Text.Relative(s) : "paired " + Item.PairedAt.ToString("MMM d");
}

/// Main-thread bridge between the engine (background) and WPF.
public class AppState : Observable
{
    public static AppState Shared { get; } = new();

    public NexusEngine Engine { get; }
    public ApiServer Api { get; }
    public RemoteServer Remote { get; }

    public ObservableCollection<ReviewRow> Reviews { get; } = [];
    public ObservableCollection<InsightRow> Insights { get; } = [];
    public ObservableCollection<RuleRow> Rules { get; } = [];
    public ObservableCollection<EventRow> Events { get; } = [];
    public ObservableCollection<JobRow> Jobs { get; } = [];
    public ObservableCollection<string> Upcoming { get; } = [];
    public ObservableCollection<ProjectRow> Projects { get; } = [];
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public ObservableCollection<string> Conflicts { get; } = [];
    public ObservableCollection<string> RecentCommands { get; } = [];

    string status = "Idle", llm = "Checking…", toast = "", focusText = "", ticker = "Ready";
    int files, review, rulesCount, insightCount, filedToday;
    bool paused, remoteRunning;
    EngineStatus engineStatus;

    public string StatusText { get => status; set => Set(ref status, value); }
    public EngineStatus EngineStatus { get => engineStatus; set => Set(ref engineStatus, value); }
    public string LlmName { get => llm; set => Set(ref llm, value); }
    public string Toast { get => toast; set => Set(ref toast, value); }
    public string FocusText { get => focusText; set => Set(ref focusText, value); }
    public string Ticker { get => ticker; set => Set(ref ticker, value); }
    public int FileCount { get => files; set => Set(ref files, value); }
    public int ReviewCount { get => review; set => Set(ref review, value); }
    public int RulesCount { get => rulesCount; set => Set(ref rulesCount, value); }
    public int InsightCount { get => insightCount; set => Set(ref insightCount, value); }
    public int FiledToday { get => filedToday; set => Set(ref filedToday, value); }
    public bool Paused { get => paused; set => Set(ref paused, value); }
    public bool RemoteRunning { get => remoteRunning; set => Set(ref remoteRunning, value); }
    public NexusSettings Settings => Engine.Settings;

    public event Action<string>? Navigate;
    readonly HashSet<string> pending = [];
    readonly object pendingLock = new();
    DispatcherTimer? flush;
    DispatcherTimer? statusTimer;
    EngineStatus? pendingStatus;

    AppState()
    {
        var store = new NexusStore();
        Engine = new NexusEngine(store);
        Api = new ApiServer(Engine);
        Remote = new RemoteServer(Api, store);
        Api.Remote = Remote;
    }

    public void Start()
    {
        Engine.Notifier = (t, b, important) => Application.Current.Dispatcher.BeginInvoke(() => Tray.Shared.Notify(t, b, important));
        Engine.StoreChanged += e => Invalidate(e);
        Engine.StatusChanged += s => Application.Current.Dispatcher.BeginInvoke(() => SetStatus(s));
        Engine.ContextSelection = ExplorerSelection.Current;
        Remote.OnChange = () => Application.Current.Dispatcher.BeginInvoke(() => { RemoteRunning = Remote.IsRunning; Reload(["remote"]); });
        Engine.Start();
        if (Settings.ApiEnabled) Api.Start(Settings.ApiPort);
        if (Settings.RemoteEnabled) Remote.Start();
        RemoteRunning = Remote.IsRunning;
        ReloadAll();
        _ = RefreshLlm();
    }

    public async Task RefreshLlm() => LlmName = await Engine.Llm.ProviderName();

    public void Stop()
    {
        Engine.Stop(); Api.Stop(); Remote.Stop();
    }

    /// "Working" only shows after 0.8 s of continuous activity and then stays at least 1.5 s — no flicker.
    void SetStatus(EngineStatus s)
    {
        if (pendingStatus == s) return;
        pendingStatus = s;
        statusTimer?.Stop();
        statusTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(s == EngineStatus.working ? 800 : 400) };
        statusTimer.Tick += (_, _) =>
        {
            statusTimer.Stop();
            pendingStatus = null;
            EngineStatus = s;
            StatusText = s switch { EngineStatus.working => "Working", EngineStatus.attention => "Needs review", EngineStatus.paused => "Paused", _ => "Idle" };
            Tray.Shared.SetStatus(s, ReviewCount);
        };
        statusTimer.Start();
    }

    public void Invalidate(string entity)
    {
        lock (pendingLock) pending.Add(entity);
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            if (flush != null) return;
            flush = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
            flush.Tick += (_, _) =>
            {
                flush!.Stop(); flush = null;
                HashSet<string> e; lock (pendingLock) { e = [.. pending]; pending.Clear(); }
                Reload(e);
            };
            flush.Start();
        });
    }

    public void ReloadAll() => Reload(["files", "rules", "projects", "jobs", "schedules", "events", "insights", "review", "settings", "focus", "remote"]);

    void Reload(IEnumerable<string> entitiesE)
    {
        var e = entitiesE.ToHashSet();
        var store = Engine.Store;
        if (e.Contains("review") || e.Contains("files")) Replace(Reviews, store.ReviewItems().Select(r => new ReviewRow(r)));
        if (e.Contains("insights")) Replace(Insights, store.Insights().Select(i => new InsightRow(i)));
        if (e.Contains("rules"))
        {
            var rules = store.Rules();
            Replace(Rules, rules.Select(r => new RuleRow(r)));
            Replace(Conflicts, Engine.RuleEngine.AnalyzeConflicts(rules).Select(c => c.Message));
        }
        if (e.Contains("projects") || e.Contains("files")) Replace(Projects, store.Projects(false).Select(p => { var s = store.ProjectStats(p.Id); return new ProjectRow(p, s.count, s.size); }));
        if (e.Contains("jobs") || e.Contains("schedules"))
        {
            Replace(Jobs, store.Jobs(150).Select(j => new JobRow(j)));
            Replace(Upcoming, Engine.Scheduler.Upcoming(20).Select(u => $"{u.at:ddd MMM d · h:mm tt}  —  {u.name}"));
        }
        if (e.Contains("events"))
        {
            var events = store.Events(300);
            Replace(Events, events.Select(x => new EventRow(x)));
            Replace(RecentCommands, store.CommandHistory(8));
            if (events.FirstOrDefault(x => x.Kind is not (EventKind.jobStarted or EventKind.jobCompleted)) is { } last) Ticker = last.Message;
            FiledToday = store.EventCount(EventKind.fileMoved, DateTime.Today);
        }
        if (e.Contains("remote")) Replace(Devices, Remote.Devices.Select(d => new DeviceRow(d)));
        if (e.Contains("settings"))
        {
            Raise(nameof(Settings));
            if (Settings.RemoteEnabled != Remote.IsRunning) { if (Settings.RemoteEnabled) Remote.Start(); else Remote.Stop(); }
            if (Settings.ApiEnabled && Api.Port == 0) Api.Start(Settings.ApiPort);
            Hotbar.Apply(Settings.Hotbar);
        }
        FileCount = store.FileCount();
        ReviewCount = store.ReviewCount();
        RulesCount = store.Rules().Count;
        InsightCount = store.Insights().Count;
        Paused = Engine.Paused;
        FocusText = Engine.Focus is { } f && store.Project(f.ProjectId) is { } fp ? $"Focus: {fp.Name} until {f.EndsAt:h:mm tt}" : "";
        Tray.Shared.SetStatus(EngineStatus, ReviewCount);
        Engine.RefreshStatus();
    }

    static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> items)
    {
        var list = items.ToList();
        target.Clear();
        foreach (var i in list) target.Add(i);
    }

    // MARK: actions

    public void SaveSettings(NexusSettings s)
    {
        var apiChanged = s.ApiEnabled != Settings.ApiEnabled || s.ApiPort != Settings.ApiPort;
        var hotkeys = s.PaletteHotkey != Settings.PaletteHotkey || s.VoiceHotkey != Settings.VoiceHotkey;
        Engine.UpdateSettings(s);
        if (apiChanged) { if (s.ApiEnabled) Api.Start(s.ApiPort); else Api.Stop(); }
        if (s.RemoteEnabled != Remote.IsRunning) { if (s.RemoteEnabled) Remote.Start(); else Remote.Stop(); }
        if (hotkeys) Hotkeys.Register(s);
        LoginItem.Apply(s.LaunchAtLogin);
        ThemeManager.Apply(s.Appearance);
        Hotbar.Apply(s.Hotbar);
        _ = RefreshLlm();
        Raise(nameof(Settings));
    }

    public void MarkOnboardingSeen()
    {
        if (Settings.OnboardingComplete) return;
        var s = Settings; s.OnboardingComplete = true; SaveSettings(s);
    }

    public async Task<CommandResult> RunCommand(string text, bool confirmed = true)
    {
        var plan = await Engine.Plan(text);
        var result = await Engine.Execute(plan);
        ShowToast(result.Message);
        if (result.Navigate != null) Navigate?.Invoke(result.Navigate);
        return result;
    }

    public void GoTo(string page) => Navigate?.Invoke(page);

    DispatcherTimer? toastTimer;
    public void ShowToast(string message)
    {
        Toast = message.Length > 260 ? message[..260] + "…" : message;
        toastTimer?.Stop();
        toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        toastTimer.Tick += (_, _) => { toastTimer.Stop(); Toast = ""; };
        toastTimer.Start();
    }
}
