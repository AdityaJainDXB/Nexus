namespace Nexus.Core;

public class JobContext(string jobId, Action<string> log)
{
    public string JobId { get; } = jobId;
    public CancellationTokenSource Cancel { get; } = new();
    public bool IsCancelled => Cancel.IsCancellationRequested;
    public void Log(string line) => log(line);
}

/// Persistent task queue: priorities, retries with backoff, cancellation, battery-aware concurrency.
public class TaskQueue(NexusStore store)
{
    public Func<Job, JobContext, Task<string>>? Runner { get; set; }
    public int MaxConcurrent { get; set; } = 2;
    /// On battery: background work continues, one job at a time.
    public Func<bool> IsThrottled { get; set; } = () => false;
    /// Low Power Mode or thermal pressure: only high & focus priority jobs start.
    public Func<bool> IsUnderPressure { get; set; } = () => false;
    public Func<bool> IsPaused { get; set; } = () => false;
    public Action? OnActivityChange { get; set; }

    readonly Dictionary<string, JobContext> running = [];
    readonly object gate = new();
    Timer? timer;
    int ticking;

    public int RunningCount { get { lock (gate) return running.Count; } }

    public void Start()
    {
        // Jobs interrupted by a crash or quit go back to the queue
        foreach (var j in store.JobsWithStatus([JobStatus.running]))
        {
            j.Status = j.Attempts < j.MaxAttempts ? JobStatus.queued : JobStatus.failed;
            j.Error ??= "Interrupted";
            store.SaveJob(j);
        }
        timer = new Timer(_ => Tick(), null, 300, 1000);
    }

    public void Stop() { timer?.Dispose(); timer = null; }

    public Job Enqueue(Job job)
    {
        job.Status = job.ScheduledFor > DateTime.Now.AddSeconds(1) ? JobStatus.scheduled : JobStatus.queued;
        store.SaveJob(job);
        Task.Run(Tick);
        return job;
    }

    public void CancelJob(string id)
    {
        lock (gate) if (running.TryGetValue(id, out var ctx)) ctx.Cancel.Cancel();
        if (store.Job(id) is { Status: JobStatus.queued or JobStatus.scheduled } j) { j.Status = JobStatus.cancelled; store.SaveJob(j); }
    }

    public void Retry(string id)
    {
        if (store.Job(id) is not { } j) return;
        j.Status = JobStatus.queued; j.Attempts = 0; j.Error = null; j.ScheduledFor = DateTime.Now;
        store.SaveJob(j);
        Task.Run(Tick);
    }

    public void Tick()
    {
        if (Runner == null || IsPaused()) return;
        if (Interlocked.Exchange(ref ticking, 1) == 1) return;
        try
        {
            var limit = IsThrottled() ? 1 : MaxConcurrent;
            var pressure = IsUnderPressure();
            int slots;
            lock (gate) slots = limit - running.Count;
            if (slots <= 0) return;
            foreach (var job in store.DueJobs(slots + 10))
            {
                lock (gate)
                {
                    if (running.Count >= limit) break;
                    if (running.ContainsKey(job.Id)) continue;
                }
                if (pressure && job.Priority < JobPriority.high) continue;
                job.Status = JobStatus.running; job.StartedAt = DateTime.Now; job.Attempts++;
                store.SaveJob(job);
                store.Log(new ActivityEvent { Kind = EventKind.jobStarted, Message = $"Started: {job.Name}", JobId = job.Id });
                var ctx = new JobContext(job.Id, line => AppendLog(job.Id, line));
                lock (gate) running[job.Id] = ctx;
                OnActivityChange?.Invoke();
                _ = Task.Run(() => Execute(job, ctx));
            }
        }
        finally { Interlocked.Exchange(ref ticking, 0); }
    }

    void AppendLog(string id, string line)
    {
        if (store.Job(id) is not { } j) return;
        j.Log.Add($"{DateTime.Now:HH:mm:ss} {line}");
        if (j.Log.Count > 200) j.Log.RemoveRange(0, j.Log.Count - 200);
        store.SaveJob(j);
    }

    async Task Execute(Job job, JobContext ctx)
    {
        try
        {
            var result = await Runner!(job, ctx);
            var j = store.Job(job.Id) ?? job;
            j.Status = ctx.IsCancelled ? JobStatus.cancelled : JobStatus.completed;
            j.FinishedAt = DateTime.Now; j.ResultSummary = result; j.Progress = 1;
            store.SaveJob(j);
            store.Log(new ActivityEvent { Kind = EventKind.jobCompleted, Message = $"{job.Name}: {result}", JobId = job.Id });
        }
        catch (Exception ex)
        {
            var j = store.Job(job.Id) ?? job;
            j.Error = ex.Message;
            if (j.Attempts < j.MaxAttempts && !ctx.IsCancelled)
            {
                j.Status = JobStatus.scheduled;
                j.ScheduledFor = DateTime.Now.AddSeconds(Math.Pow(4, j.Attempts) * 5);   // 20s, 80s, 5min
            }
            else j.Status = JobStatus.failed;
            j.FinishedAt = DateTime.Now;
            store.SaveJob(j);
            store.Log(new ActivityEvent { Kind = EventKind.jobFailed, Message = $"{job.Name} failed: {ex.Message}", JobId = job.Id });
        }
        finally
        {
            lock (gate) running.Remove(job.Id);
            OnActivityChange?.Invoke();
            Tick();
        }
    }
}

public class SystemSnapshot
{
    public double DiskFreeGB { get; set; }
    public double DiskTotalGB { get; set; }
    public double IdleSeconds { get; set; }
    public bool OnAcPower { get; set; } = true;
    public bool LowPowerMode { get; set; }
    public List<string> Volumes { get; set; } = [];
    public bool ShouldThrottle => !OnAcPower || UnderPressure;
    public bool UnderPressure => LowPowerMode;
}

/// Turns schedules (once / cron / conditional) and maintenance hooks into queued jobs.
public class Scheduler(NexusStore store, TaskQueue queue)
{
    public Func<SystemSnapshot> Snapshot { get; set; } = () => new SystemSnapshot();
    public List<(string name, TimeSpan interval, Action run)> Maintenance { get; } = [];
    readonly Dictionary<string, DateTime> lastMaintenance = [];
    Timer? timer;

    public void Start() => timer = new Timer(_ => Tick(DateTime.Now), null, 1500, 20_000);
    public void Stop() { timer?.Dispose(); timer = null; }
    public void TickNow() => Task.Run(() => Tick(DateTime.Now));

    public void Tick(DateTime now)
    {
        foreach (var s in store.Schedules().Where(s => s.Enabled))
        {
            try { Consider(s, now); } catch { }
        }
        foreach (var (name, interval, run) in Maintenance)
        {
            var last = lastMaintenance.TryGetValue(name, out var l) ? l : (DateTime.TryParse(store.Kv("maint:" + name), out var p) ? p : DateTime.MinValue);
            if (now - last < interval) continue;
            lastMaintenance[name] = now;
            store.SetKv("maint:" + name, now.ToString("o"));
            try { run(); } catch { }
        }
    }

    void Consider(Schedule s, DateTime now)
    {
        switch (s.Mode)
        {
            case ScheduleMode.once:
                if (s.RunAt is { } at && at <= now && s.LastRunAt == null)
                {
                    Fire(s);
                    s.Enabled = false; s.LastRunAt = now; s.NextRunAt = null;
                    store.SaveSchedule(s);
                }
                break;
            case ScheduleMode.recurring:
                if (s.Cron == null || CronExpression.Parse(s.Cron) is not { } cron) return;
                s.NextRunAt ??= cron.Next(s.LastRunAt ?? now.AddMinutes(-1));
                if (s.NextRunAt <= now)
                {
                    Fire(s);
                    s.LastRunAt = now; s.NextRunAt = cron.Next(now);
                }
                store.SaveSchedule(s);
                break;
            case ScheduleMode.conditional:
                if (s.LastRunAt is { } last && (now - last).TotalMinutes < s.CooldownMinutes) return;
                var snap = Snapshot();
                if (s.Conditions.All(c => ConditionHolds(c, snap, now)))
                {
                    Fire(s);
                    s.LastRunAt = now;
                    store.SaveSchedule(s);
                }
                break;
        }
    }

    public static bool ConditionHolds(SystemCondition c, SystemSnapshot snap, DateTime now)
    {
        switch (c.Kind)
        {
            case SystemConditionKind.folderCountAbove:
                var f = Paths.Expand(c.Folder ?? "~/Downloads");
                try { return Directory.Exists(f) && Directory.EnumerateFileSystemEntries(f).Count() > c.Number; } catch { return false; }
            case SystemConditionKind.folderSizeAboveGB:
                return FolderStats(Paths.Expand(c.Folder ?? "~/Downloads")).size / 1e9 > c.Number;
            case SystemConditionKind.diskFreeBelowGB: return snap.DiskFreeGB < c.Number;
            case SystemConditionKind.hourAtLeast: return now.Hour >= c.Number;
            case SystemConditionKind.idleMinutes: return snap.IdleSeconds / 60 >= c.Number;
            case SystemConditionKind.onACPower: return snap.OnAcPower;
            default: return false;
        }
    }

    public static (long size, int count) FolderStats(string folder)
    {
        long size = 0; var count = 0;
        try
        {
            foreach (var f in new DirectoryInfo(folder).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint }))
            { size += f.Length; if (++count > 200_000) break; }
        }
        catch { }
        return (size, count);
    }

    void Fire(Schedule s)
    {
        queue.Enqueue(new Job { Name = s.Name, Kind = s.JobKind, Priority = s.Priority, Spec = s.Job, ScheduleId = s.Id, MaxAttempts = 2 });
        store.Log(new ActivityEvent { Kind = EventKind.system, Message = $"Schedule fired: {s.Name}" });
    }

    public List<(DateTime at, string name)> Upcoming(int limit = 30, int horizonDays = 14)
    {
        var now = DateTime.Now;
        var outList = new List<(DateTime, string)>();
        foreach (var s in store.Schedules().Where(s => s.Enabled))
        {
            if (s.Mode == ScheduleMode.once && s.RunAt is { } at && at > now) outList.Add((at, s.Name));
            if (s.Mode == ScheduleMode.recurring && s.Cron != null && CronExpression.Parse(s.Cron) is { } cron)
            {
                var t = now;
                for (var i = 0; i < 5; i++)
                {
                    if (cron.Next(t) is not { } n || n > now.AddDays(horizonDays)) break;
                    outList.Add((n, s.Name)); t = n;
                }
            }
        }
        return outList.OrderBy(x => x.Item1).Take(limit).ToList();
    }
}
