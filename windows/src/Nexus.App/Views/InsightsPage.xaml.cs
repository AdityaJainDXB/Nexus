using System.Windows;
using System.Windows.Controls;
using Nexus.Core;

namespace Nexus.App;

public partial class InsightsPage : UserControl
{
    AppState S => AppState.Shared;
    public InsightsPage() => InitializeComponent();
    static InsightRow Row(object s) => (InsightRow)((FrameworkElement)s).Tag;
    void Fix_Click(object sender, RoutedEventArgs e) { if (Row(sender).Item.Command is { } c) Palette.ShowWith(c); }
    void Dismiss_Click(object sender, RoutedEventArgs e) => S.Engine.Store.DismissInsight(Row(sender).Item.Id);
    void Scan_Click(object sender, RoutedEventArgs e)
    {
        S.Engine.Queue.Enqueue(new Job { Name = "Scan for insights", Kind = JobKind.ai, Priority = JobPriority.high, Spec = new JobSpec { Operation = JobOperation.scanInsights } });
        S.ShowToast("Scanning your folders…");
    }
}
