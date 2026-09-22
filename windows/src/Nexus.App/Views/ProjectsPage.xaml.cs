using System.Windows;
using System.Windows.Controls;
using Nexus.Core;

namespace Nexus.App;

public partial class ProjectsPage : UserControl
{
    AppState S => AppState.Shared;
    public ProjectsPage() => InitializeComponent();
    static ProjectRow Row(object s) => (ProjectRow)((FrameworkElement)s).Tag;

    void Create_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(NameBox.Text)) return;
        var p = new Project { Name = NameBox.Text.Trim(), Keywords = Keywords.Text.Split(',').Select(k => k.Trim()).Where(k => k.Length > 0).ToList(), Color = NexusEngine.Palette[Random.Shared.Next(NexusEngine.Palette.Length)] };
        S.Engine.Store.SaveProject(p);
        S.Engine.RebuildProjectVectors();
        NameBox.Clear(); Keywords.Clear();
        S.ShowToast($"Project “{p.Name}” created");
    }

    void Focus_Click(object sender, RoutedEventArgs e) { S.Engine.StartFocus(Row(sender).Item.Id, 120); S.ShowToast($"Focusing on {Row(sender).Name} for 2 hours"); }
    async void Summarize_Click(object sender, RoutedEventArgs e) => S.ShowToast((await S.RunCommand($"summarize project {Row(sender).Name}")).Message);
    void Archive_Click(object sender, RoutedEventArgs e) { var p = Row(sender).Item; p.Archived = true; S.Engine.Store.SaveProject(p); }
}
