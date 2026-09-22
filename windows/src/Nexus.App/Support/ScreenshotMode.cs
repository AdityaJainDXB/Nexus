using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Nexus.App;

/// NEXUS_SCREENSHOT_DIR=… renders every page, the palette and the hotbar to PNGs (README / CI), then exits.
public static class ScreenshotMode
{
    public static List<string> Errors { get; } = [];

    /// Renders every window; any XAML or binding failure is recorded and fails the run (exit code 1).
    public static async Task Capture(string dir)
    {
        Directory.CreateDirectory(dir);
        await Task.Delay(1500);
        async Task Shot(string name, Func<Task> body)
        {
            try { await body(); }
            catch (Exception ex) { Errors.Add($"{name}: {ex}"); }
        }
        MainWindow? w = null;
        await Shot("main", async () =>
        {
            w = new MainWindow { Width = 1280, Height = 800, WindowStartupLocation = WindowStartupLocation.Manual, Left = 0, Top = 0, ShowActivated = false };
            w.Show();
            await Task.Delay(500);
        });
        string[] pages = ["today", "review", "files", "projects", "rules", "tasks", "insights", "activity", "remote", "settings"];
        for (var i = 0; i < pages.Length && w != null; i++)
        {
            var page = pages[i]; var n = i + 1;
            await Shot(page, async () =>
            {
                w!.Navigate(page);
                await Task.Delay(900);
                if (w.Current != page) throw new InvalidOperationException($"navigation to {page} failed");
                Save(w, Path.Combine(dir, $"win-{n:00}-{page}.png"));
            });
        }
        w?.Close();
        await Shot("onboarding", async () =>
        {
            var o = new OnboardingWindow { WindowStartupLocation = WindowStartupLocation.Manual, Left = 0, Top = 0, ShowActivated = false };
            o.Show(); await Task.Delay(700);
            Save(o, Path.Combine(dir, "win-11-onboarding.png"));
            o.Close();
        });
        await Shot("hotbar", async () =>
        {
            var hb = new Hotbar { Left = 0, Top = 0 };
            hb.Show(); await Task.Delay(600);
            Save(hb, Path.Combine(dir, "win-12-hotbar.png"));
            hb.Close();
        });
        await Shot("palette", async () =>
        {
            Palette.ShowWith("clean up duplicates");
            await Task.Delay(2500);
            if (Application.Current.Windows.OfType<Palette>().FirstOrDefault() is { } pal) { Save(pal, Path.Combine(dir, "win-13-palette.png")); pal.Hide(); }
            else throw new InvalidOperationException("palette did not open");
        });
        File.WriteAllLines(Path.Combine(dir, "errors.txt"), Errors);
    }

    static void Save(Window w, string path)
    {
        w.UpdateLayout();
        var el = (FrameworkElement)w.Content;
        var dpi = VisualTreeHelper.GetDpi(w);
        var width = (int)(el.ActualWidth * dpi.DpiScaleX); var height = (int)(el.ActualHeight * dpi.DpiScaleY);
        if (width == 0 || height == 0) return;
        var rtb = new RenderTargetBitmap(width, height, 96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32);
        var bg = new DrawingVisual();
        using (var dc = bg.RenderOpen()) dc.DrawRectangle((Brush)Application.Current.Resources["Bg"], null, new Rect(0, 0, el.ActualWidth, el.ActualHeight));
        rtb.Render(bg);
        rtb.Render(el);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var fs = File.Create(path);
        enc.Save(fs);
    }
}
