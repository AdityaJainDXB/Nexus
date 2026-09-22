using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Nexus.App;

/// NEXUS_SCREENSHOT_DIR=… renders every page, the palette and the hotbar to PNGs (README / CI), then exits.
public static class ScreenshotMode
{
    public static async Task Capture(string dir)
    {
        Directory.CreateDirectory(dir);
        await Task.Delay(1500);
        var w = new MainWindow { Width = 1280, Height = 800, WindowStartupLocation = WindowStartupLocation.Manual, Left = 0, Top = 0, ShowActivated = false };
        w.Show();
        string[] pages = ["today", "review", "files", "projects", "rules", "tasks", "insights", "activity", "remote", "settings"];
        for (var i = 0; i < pages.Length; i++)
        {
            w.Navigate(pages[i]);
            await Task.Delay(900);
            Save(w, Path.Combine(dir, $"win-{i + 1:00}-{pages[i]}.png"));
        }
        w.Close();
        var hb = new Hotbar { Left = 0, Top = 0 };
        hb.Show(); await Task.Delay(600);
        Save(hb, Path.Combine(dir, "win-12-hotbar.png"));
        hb.Close();
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
