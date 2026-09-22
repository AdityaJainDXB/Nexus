using System.Runtime.InteropServices;
using System.Speech.Recognition;
using System.Speech.Synthesis;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Nexus.Core;
using Forms = System.Windows.Forms;

namespace Nexus.App;

/// Windows implementations of the engine's platform hooks.
public class WindowsPlatform : Platform
{
    public override string? Ocr(string path)
    {
        try
        {
            return Task.Run(async () =>
            {
                var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
                using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
                var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
                using var bitmap = await decoder.GetSoftwareBitmapAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied);
                var engine = Windows.Media.Ocr.OcrEngine.TryCreateFromUserProfileLanguages();
                if (engine == null) return null;
                if (bitmap.PixelWidth > Windows.Media.Ocr.OcrEngine.MaxImageDimension || bitmap.PixelHeight > Windows.Media.Ocr.OcrEngine.MaxImageDimension) return null;
                var result = await engine.RecognizeAsync(bitmap);
                return result.Text;
            }).GetAwaiter().GetResult();
        }
        catch { return null; }
    }

    /// dHash: 9×8 grayscale, one bit per horizontal gradient.
    public override ulong? ImageHash(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            var decoder = BitmapDecoder.Create(fs, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
            BitmapSource frame = decoder.Frames[0];
            var scaled = new TransformedBitmap(frame, new ScaleTransform(9.0 / frame.PixelWidth, 8.0 / frame.PixelHeight));
            var gray = new FormatConvertedBitmap(scaled, PixelFormats.Gray8, null, 0);
            var px = new byte[gray.PixelWidth * gray.PixelHeight];
            gray.CopyPixels(px, gray.PixelWidth, 0);
            if (gray.PixelWidth < 9 || gray.PixelHeight < 8) return null;
            ulong hash = 0; var bit = 0;
            for (var y = 0; y < 8; y++)
                for (var x = 0; x < 8; x++, bit++)
                    if (px[y * gray.PixelWidth + x] > px[y * gray.PixelWidth + x + 1]) hash |= 1UL << bit;
            return hash;
        }
        catch { return null; }
    }

    public override bool OnAcPower => Forms.SystemInformation.PowerStatus.PowerLineStatus != Forms.PowerLineStatus.Offline;
    public override bool LowPowerMode
    {
        get { try { return Windows.System.Power.PowerManager.EnergySaverStatus == Windows.System.Power.EnergySaverStatus.On; } catch { return false; } }
    }

    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    public override double IdleSeconds
    {
        get
        {
            var i = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
            return GetLastInputInfo(ref i) ? (Environment.TickCount - (int)i.dwTime) / 1000.0 : 0;
        }
    }

    public override void Notify(string title, string body, bool important) => Application.Current?.Dispatcher.BeginInvoke(() => Tray.Shared.Notify(title, body, important));
}

/// System tray icon: status, quick actions, notifications.
public class Tray
{
    public static Tray Shared { get; } = new();
    Forms.NotifyIcon? icon;
    Forms.ToolStripMenuItem? statusItem, reviewItem, pauseItem;

    public void Show()
    {
        if (icon != null) return;
        icon = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(Application.GetResourceStream(new Uri("pack://application:,,,/Assets/nexus.ico"))!.Stream),
            Text = "Nexus", Visible = true,
        };
        var menu = new Forms.ContextMenuStrip { ShowImageMargin = false, Font = new System.Drawing.Font("Segoe UI", 9.5f) };
        statusItem = new Forms.ToolStripMenuItem("Nexus · Idle") { Enabled = false };
        reviewItem = new Forms.ToolStripMenuItem("Review Queue", null, (_, _) => App.ShowMain("review"));
        pauseItem = new Forms.ToolStripMenuItem("Pause automations", null, (_, _) => AppState.Shared.Engine.SetPaused(!AppState.Shared.Engine.Paused));
        menu.Items.AddRange([
            statusItem, new Forms.ToolStripSeparator(),
            new Forms.ToolStripMenuItem($"Ask Nexus…  ({AppState.Shared.Settings.PaletteHotkey})", null, (_, _) => Palette.Toggle()),
            new Forms.ToolStripMenuItem($"Talk to Nexus  ({AppState.Shared.Settings.VoiceHotkey})", null, (_, _) => Palette.ShowVoice()),
            new Forms.ToolStripMenuItem("Organize Downloads", null, async (_, _) => await AppState.Shared.RunCommand("organize Downloads")),
            reviewItem,
            new Forms.ToolStripMenuItem("Insights", null, (_, _) => App.ShowMain("insights")),
            new Forms.ToolStripSeparator(),
            new Forms.ToolStripMenuItem("Undo last automation", null, (_, _) => AppState.Shared.ShowToast(AppState.Shared.Engine.UndoLast() is var n && n > 0 ? $"Undid {n} operation(s)" : "Nothing to undo")),
            pauseItem,
            new Forms.ToolStripMenuItem("Open Nexus", null, (_, _) => App.ShowMain(null)),
            new Forms.ToolStripMenuItem("Settings", null, (_, _) => App.ShowMain("settings")),
            new Forms.ToolStripSeparator(),
            new Forms.ToolStripMenuItem("Quit Nexus", null, (_, _) => Application.Current.Shutdown()),
        ]);
        icon.ContextMenuStrip = menu;
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) App.ShowMain(null); };
        icon.BalloonTipClicked += (_, _) => App.ShowMain(AppState.Shared.ReviewCount > 0 ? "review" : "today");
    }

    public void SetStatus(EngineStatus s, int review)
    {
        if (icon == null || statusItem == null) return;
        var label = s switch { EngineStatus.working => "Working…", EngineStatus.attention => $"{review} to review", EngineStatus.paused => "Paused", _ => "Idle" };
        statusItem.Text = "Nexus · " + label;
        icon.Text = ("Nexus — " + label).Length > 63 ? "Nexus" : "Nexus — " + label;
        reviewItem!.Text = review > 0 ? $"Review Queue ({review})" : "Review Queue";
        pauseItem!.Text = s == EngineStatus.paused ? "Resume automations" : "Pause automations";
    }

    public void Notify(string title, string body, bool important)
    {
        if (icon == null) { AppState.Shared.ShowToast($"{title}: {body}"); return; }
        icon.ShowBalloonTip(important ? 8000 : 4000, title, body.Length > 250 ? body[..250] : body, important ? Forms.ToolTipIcon.Info : Forms.ToolTipIcon.None);
    }

    public void Dispose() { if (icon != null) { icon.Visible = false; icon.Dispose(); icon = null; } }
}

/// Global hotkeys via RegisterHotKey on a message-only window.
public static class Hotkeys
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    static HwndSource? source;
    const int PaletteId = 0x4E01, VoiceId = 0x4E02;
    public static List<string> Failed { get; } = [];

    public static readonly string[] PaletteChoices = ["Ctrl+Alt+N", "Ctrl+Shift+Space", "Alt+Shift+N", "Ctrl+Alt+K"];
    public static readonly string[] VoiceChoices = ["Ctrl+Alt+Space", "Alt+Shift+Space", "Ctrl+Alt+V"];

    public static void Register(NexusSettings s)
    {
        if (source == null)
        {
            source = new HwndSource(new HwndSourceParameters("NexusHotkeys") { Width = 0, Height = 0, WindowStyle = 0, ParentWindow = new IntPtr(-3) });
            source.AddHook(Hook);
        }
        UnregisterHotKey(source.Handle, PaletteId); UnregisterHotKey(source.Handle, VoiceId);
        Failed.Clear();
        if (!Bind(PaletteId, s.PaletteHotkey)) Failed.Add(s.PaletteHotkey);
        if (!Bind(VoiceId, s.VoiceHotkey)) Failed.Add(s.VoiceHotkey);
    }

    static bool Bind(int id, string combo)
    {
        uint mods = 0x4000; // MOD_NOREPEAT
        uint vk = 0;
        foreach (var part in combo.Split('+').Select(p => p.Trim().ToLowerInvariant()))
        {
            switch (part)
            {
                case "ctrl": mods |= 0x2; break;
                case "alt": mods |= 0x1; break;
                case "shift": mods |= 0x4; break;
                case "win": mods |= 0x8; break;
                case "space": vk = 0x20; break;
                default: if (part.Length == 1) vk = char.ToUpperInvariant(part[0]); break;
            }
        }
        return vk != 0 && RegisterHotKey(source!.Handle, id, mods, vk);
    }

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x0312)
        {
            if (wParam.ToInt32() == PaletteId) Palette.Toggle();
            if (wParam.ToInt32() == VoiceId) Palette.ShowVoice();
            handled = true;
        }
        return IntPtr.Zero;
    }
}

public static class LoginItem
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static void Apply(bool enabled)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key, true);
            if (k == null) return;
            if (enabled) k.SetValue("Nexus", $"\"{Environment.ProcessPath}\" --background");
            else k.DeleteValue("Nexus", false);
        }
        catch { }
    }
}

/// Light/dark palettes; "system" follows Windows' app theme.
public static class ThemeManager
{
    public static bool IsDark { get; private set; } = true;

    public static void Apply(string appearance)
    {
        var dark = appearance switch { "dark" => true, "light" => false, _ => SystemIsDark() };
        IsDark = dark;
        var r = Application.Current.Resources;
        void C(string key, string hex) => r[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        if (dark)
        {
            C("Bg", "#090D17"); C("BgElevated", "#0E1422"); C("Panel", "#111A2B"); C("PanelHover", "#16223A"); C("Line", "#1F2C45"); C("LineStrong", "#2B3C5C");
            C("Text", "#E8EEF8"); C("TextMuted", "#8C9AB3"); C("TextFaint", "#5B6882"); C("Accent", "#39E2FF"); C("AccentSoft", "#1A39E2FF"); C("OnAccent", "#04121A");
            C("Good", "#3DF5A0"); C("Warn", "#FFB547"); C("Bad", "#FF5C7A"); C("Violet", "#8F7CFF");
        }
        else
        {
            C("Bg", "#F4F7FB"); C("BgElevated", "#FFFFFF"); C("Panel", "#FFFFFF"); C("PanelHover", "#EEF3FA"); C("Line", "#DDE4EE"); C("LineStrong", "#C7D1DF");
            C("Text", "#0D1220"); C("TextMuted", "#55627A"); C("TextFaint", "#8A96AA"); C("Accent", "#0A8FB8"); C("AccentSoft", "#1A0A8FB8"); C("OnAccent", "#FFFFFF");
            C("Good", "#0E9F6E"); C("Warn", "#B7791F"); C("Bad", "#D63B5A"); C("Violet", "#6A55E0");
        }
    }

    static bool SystemIsDark()
    {
        try { return Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("AppsUseLightTheme") is int v && v == 0; }
        catch { return true; }
    }
}

/// Files selected in the front File Explorer window — powers "file this" / "summarize these".
public static class ExplorerSelection
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    static IntPtr lastExplorer;
    static List<string> snapshot = [];

    /// Called just before Nexus takes focus (hotkey) so we capture the user's selection.
    public static void Capture()
    {
        var fg = GetForegroundWindow();
        snapshot = Read(fg);
        if (snapshot.Count > 0) lastExplorer = fg;
    }

    public static IReadOnlyList<string> Current() => snapshot.Count > 0 ? snapshot : Read(lastExplorer);

    static List<string> Read(IntPtr hwnd)
    {
        var list = new List<string>();
        if (hwnd == IntPtr.Zero) return list;
        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType == null) return list;
            dynamic shell = Activator.CreateInstance(shellType)!;
            foreach (var w in shell.Windows())
            {
                try
                {
                    if ((IntPtr)(long)w.HWND != hwnd) continue;
                    foreach (var item in w.Document.SelectedItems()) list.Add((string)item.Path);
                }
                catch { }
            }
        }
        catch { }
        return list;
    }
}

/// Offline speech: Windows' built-in recognizer and voices (System.Speech / SAPI).
public class Voice : IDisposable
{
    public static Voice Shared { get; } = new();
    SpeechRecognitionEngine? recognizer;
    readonly SpeechSynthesizer synth = new();
    public event Action<string>? Partial;
    public event Action<string>? Final;
    public event Action<string>? Error;
    public bool Listening { get; private set; }

    public static bool Available
    {
        get { try { return SpeechRecognitionEngine.InstalledRecognizers().Count > 0; } catch { return false; } }
    }

    public void Listen()
    {
        try
        {
            if (recognizer == null)
            {
                var info = SpeechRecognitionEngine.InstalledRecognizers().FirstOrDefault(r => r.Culture.Name.StartsWith("en")) ?? SpeechRecognitionEngine.InstalledRecognizers().FirstOrDefault();
                if (info == null) { Error?.Invoke("No speech recognizer installed. Add “Speech” in Settings → Time & language → Speech."); return; }
                recognizer = new SpeechRecognitionEngine(info);
                recognizer.LoadGrammar(new DictationGrammar());
                recognizer.SetInputToDefaultAudioDevice();
                recognizer.EndSilenceTimeout = TimeSpan.FromSeconds(0.9);
                recognizer.InitialSilenceTimeout = TimeSpan.FromSeconds(6);
                recognizer.SpeechHypothesized += (_, e) => Partial?.Invoke(e.Result.Text);
                recognizer.SpeechRecognized += (_, e) => { Listening = false; Final?.Invoke(e.Result.Text); };
                recognizer.RecognizeCompleted += (_, e) => { Listening = false; if (e.Error != null) Error?.Invoke(e.Error.Message); else if (e.Result == null) Final?.Invoke(""); };
            }
            Listening = true;
            recognizer.RecognizeAsync(RecognizeMode.Single);
        }
        catch (Exception ex) { Listening = false; Error?.Invoke(ex.Message.Contains("audio") ? "No microphone found." : ex.Message); }
    }

    public void Stop() { try { recognizer?.RecognizeAsyncCancel(); } catch { } Listening = false; }

    public void Speak(string text)
    {
        if (!AppState.Shared.Settings.SpeakResponses || string.IsNullOrWhiteSpace(text)) return;
        try { synth.SpeakAsyncCancelAll(); synth.SpeakAsync(text.Length > 400 ? text[..400] : text); } catch { }
    }

    public void Dispose() { recognizer?.Dispose(); synth.Dispose(); }
}
