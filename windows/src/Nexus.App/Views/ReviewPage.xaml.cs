using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Nexus.Core;

namespace Nexus.App;

public partial class ReviewPage : UserControl
{
    AppState S => AppState.Shared;

    public ReviewPage()
    {
        InitializeComponent();
        S.Reviews.CollectionChanged += (_, _) => Update();
        Loaded += (_, _) => { Update(); if (List.Items.Count > 0) { List.SelectedIndex = 0; List.Focus(); } };
    }

    void Update() => Empty.Visibility = S.Reviews.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    static ReviewRow Row(object sender) => (ReviewRow)((FrameworkElement)sender).Tag;

    async void Approve_Click(object sender, RoutedEventArgs e) { await S.Engine.Approve(Row(sender).Item); S.ShowToast($"Filed {Row(sender).Name}"); }
    void Reject_Click(object sender, RoutedEventArgs e) => S.Engine.Reject(Row(sender).Item);
    void Reveal_Click(object sender, RoutedEventArgs e) => Platform.Current.Reveal(Row(sender).Item.Path);

    async void Alt_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ComboBox { SelectedItem: string folder } cb)
        {
            await S.Engine.Approve(((ReviewRow)cb.Tag).Item, Paths.Expand(folder));
            S.ShowToast($"Filed to {folder} — Nexus will remember");
        }
    }

    async void ApproveAll_Click(object sender, RoutedEventArgs e)
    {
        var items = S.Reviews.Select(r => r.Item).ToList();
        foreach (var i in items) await S.Engine.Approve(i);
        S.ShowToast($"Filed {items.Count} files");
    }

    void RejectAll_Click(object sender, RoutedEventArgs e) { foreach (var i in S.Reviews.Select(r => r.Item).ToList()) S.Engine.Reject(i); }

    async void List_KeyDown(object sender, KeyEventArgs e)
    {
        if (List.SelectedItem is not ReviewRow row || e.Key != Key.Enter) return;
        var index = List.SelectedIndex;
        if (Keyboard.Modifiers == ModifierKeys.Shift) S.Engine.Reject(row.Item); else await S.Engine.Approve(row.Item);
        e.Handled = true;
        await Task.Delay(450);
        if (List.Items.Count > 0) { List.SelectedIndex = Math.Min(index, List.Items.Count - 1); List.Focus(); }
    }
}
