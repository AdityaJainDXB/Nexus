using System.IO.Pipes;
using System.Windows;
using System.Windows.Threading;
using Nexus.Core;

namespace Nexus.App;

public partial class App : Application
{
    static Mutex? single;
    static MainWindow? main;
    public static bool Headless { get; } = Environment.GetEnvironmentVariable("NEXUS_HEADLESS") == "1";
    const string PipeName = "Nexus.Activate";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var link = e.Args.FirstOrDefault(a => a.StartsWith("nexus:", StringComparison.OrdinalIgnoreCase));
        single = new Mutex(true, Headless ? "Nexus.SingleInstance.Headless." + Environment.ProcessId : "Nexus.SingleInstance", out var first);
        if (!first)
        {
            // Nexus is already running: hand it the link (or just bring it forward) and exit
            try { using var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out); c.Connect(1500); using var w = new StreamWriter(c); w.Write(link ?? "nexus://open"); } catch { }
            Shutdown();
            return;
        }
        DispatcherUnhandledException += (_, ex) =>
        {
            try { File.AppendAllText(Path.Combine(Paths.AppSupport, "crash.log"), $"{DateTime.Now:o} {ex.Exception}\n"); } catch { }
            ex.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => { try { File.AppendAllText(Path.Combine(Paths.AppSupport, "crash.log"), $"{DateTime.Now:o} {ex.ExceptionObject}\n"); } catch { } };
        TaskScheduler.UnobservedTaskException += (_, ex) => { try { File.AppendAllText(Path.Combine(Paths.AppSupport, "crash.log"), $"{DateTime.Now:o} task: {ex.Exception}\n"); } catch { } ex.SetObserved(); };
        Platform.Current = new WindowsPlatform();
        ThemeManager.Apply(new NexusStore().LoadSettings().Appearance);
        var state = AppState.Shared;
        state.Start();
        ThemeManager.Apply(state.Settings.Appearance);

        if (Environment.GetEnvironmentVariable("NEXUS_SCREENSHOT_DIR") is { Length: > 0 } shots)
        {
            Dispatcher.BeginInvoke(async () => { await ScreenshotMode.Capture(shots); Shutdown(ScreenshotMode.Errors.Count == 0 ? 0 : 1); }, DispatcherPriority.ApplicationIdle);
            return;
        }
        if (Headless) return;

        Tray.Shared.Show();
        Hotkeys.Register(state.Settings);
        LoginItem.Apply(state.Settings.LaunchAtLogin);
        Hotbar.Apply(state.Settings.Hotbar);
        ListenForActivation();
        var background = e.Args.Contains("--background");
        if (!state.Settings.OnboardingComplete) ShowOnboarding();
        else if (!background) ShowMain(null);
        if (link != null) HandleLink(link);
        if (Hotkeys.Failed.Count > 0) Tray.Shared.Notify("Shortcut unavailable", $"{string.Join(", ", Hotkeys.Failed)} is used by another app — pick another in Settings.", false);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { AppState.Shared.Stop(); } catch { }
        Tray.Shared.Dispose();
        Voice.Shared.Dispose();
        base.OnExit(e);
    }

    static void ListenForActivation()
    {
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync();
                    using var r = new StreamReader(server);
                    var msg = await r.ReadToEndAsync();
                    Current.Dispatcher.Invoke(() => HandleLink(msg));
                }
                catch { await Task.Delay(1000); }
            }
        });
    }

    /// nexus://palette · nexus://voice · nexus://run?cmd=… · nexus://review (any page)
    public static void HandleLink(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri)) { ShowMain(null); return; }
        var target = (uri.Host + uri.AbsolutePath).Trim('/').ToLowerInvariant();
        switch (target)
        {
            case "palette": Palette.Toggle(); break;
            case "voice": Palette.ShowVoice(); break;
            case "run":
                var q = System.Web.HttpUtility.ParseQueryString(uri.Query)["cmd"];
                if (!string.IsNullOrWhiteSpace(q)) Palette.ShowWith(q);
                break;
            case "open" or "": ShowMain(null); break;
            default: ShowMain(target); break;
        }
    }

    public static void ShowMain(string? page)
    {
        if (main == null) { main = new MainWindow(); main.Closed += (_, _) => main = null; }
        if (page != null) main.Navigate(page);
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }

    public static void ShowOnboarding()
    {
        var w = new OnboardingWindow();
        w.Closed += (_, _) => { AppState.Shared.MarkOnboardingSeen(); ShowMain("today"); };
        w.Show();
        w.Activate();
    }
}
