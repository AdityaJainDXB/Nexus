using System.Windows;
using System.Windows.Controls;

namespace Nexus.App;

public partial class ActivityPage : UserControl
{
    public ActivityPage() => InitializeComponent();
    void Undo_Click(object sender, RoutedEventArgs e)
    {
        var n = AppState.Shared.Engine.UndoLast();
        AppState.Shared.ShowToast(n > 0 ? $"Undid {n} operation{(n == 1 ? "" : "s")}" : "Nothing to undo");
    }
}
