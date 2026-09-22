using System.Windows;
using System.Windows.Controls;

namespace Nexus.App;

public partial class TasksPage : UserControl
{
    AppState S => AppState.Shared;
    public TasksPage() => InitializeComponent();
    void Retry_Click(object sender, RoutedEventArgs e) => S.Engine.Queue.Retry(((JobRow)((FrameworkElement)sender).Tag).Item.Id);
    async void Add_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(Sched.Text)) return;
        var r = await S.RunCommand(Sched.Text);
        Sched.Clear();
        S.ShowToast(r.Message);
    }
}
