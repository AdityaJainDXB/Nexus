using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Nexus.Core;

namespace Nexus.App;

public partial class FilesPage : UserControl
{
    AppState S => AppState.Shared;
    FileRow? selected;

    public FilesPage()
    {
        InitializeComponent();
        Loaded += (_, _) => { Query.Focus(); Search(""); };
    }

    void Search(string text)
    {
        var files = string.IsNullOrWhiteSpace(text) ? S.Engine.Store.Files(200)
            : S.Engine.Resolve(new CommandParser(new NLRuleCompiler(S.Settings.LibraryRoots.FirstOrDefault() ?? "~/Documents")).Query(text), []);
        Results.ItemsSource = files.Where(f => File.Exists(f.Path)).Take(300).Select(f => new FileRow(f)).ToList();
        Hint.Text = string.IsNullOrWhiteSpace(text) ? $"{S.FileCount} files understood. Search names, contents, OCR text, people and dates." : $"{Results.Items.Count} results for “{text}”";
    }

    void Query_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) Search(Query.Text); }

    void Results_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Results.SelectedItem is not FileRow row) { Detail.Visibility = Visibility.Collapsed; return; }
        selected = row;
        Detail.Visibility = Visibility.Visible;
        var f = row.Item;
        DName.Text = f.Name;
        DMeta.Text = $"{Paths.Abbreviate(f.Folder)}\n{f.Kind} · {Text.FormatBytes(f.Size)} · modified {f.ModifiedAt:MMM d, yyyy}" +
            (f.DocType != null ? $"\nLooks like: {f.DocType} ({(int)(f.Confidence * 100)}%)" : "") +
            (f.Entities.Count > 0 ? "\n" + string.Join(" · ", f.Entities.Take(6).Select(x => x.Value)) : "") +
            (f.SourceUrl != null ? $"\nDownloaded from {new Uri(f.SourceUrl, UriKind.RelativeOrAbsolute)}" : "");
        DSnippet.Text = f.Summary ?? (f.Snippet.Length == 0 ? "No text found in this file." : f.Snippet);
        Related.ItemsSource = S.Engine.Related(f, 6).Select(r => $"• {r.file.Name}").ToList();
    }

    void Results_DoubleClick(object sender, MouseButtonEventArgs e) { if (selected != null) Platform.Current.Open(selected.Item.Path); }
    void Open_Click(object sender, RoutedEventArgs e) { if (selected != null) Platform.Current.Open(selected.Item.Path); }
    void Reveal_Click(object sender, RoutedEventArgs e) { if (selected != null) Platform.Current.Reveal(selected.Item.Path); }

    async void Summarize_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return;
        DSnippet.Text = "Summarizing on-device…";
        var f = selected.Item;
        f.Summary = await S.Engine.Summarize(f);
        S.Engine.Store.UpsertFile(f);
        DSnippet.Text = f.Summary;
    }

    async void FileIt_Click(object sender, RoutedEventArgs e)
    {
        if (selected == null) return;
        var best = S.Engine.Suggestions(selected.Item).FirstOrDefault();
        if (best == null) { S.ShowToast("No confident destination yet — move it once and Nexus will learn."); return; }
        var (_, outc) = await S.Engine.Executor.Run([new RuleAction(ActionKind.move, best.Folder)], selected.Item);
        S.Engine.Taxonomy.Reinforce(best.Folder, selected.Item.DocType, Classifier.Tokens(selected.Item.Name));
        S.ShowToast(outc.FirstOrDefault()?.Success == true ? $"Filed to {Paths.Abbreviate(best.Folder)} — undo from the tray or Activity" : outc.FirstOrDefault()?.Message ?? "");
        Search(Query.Text);
    }
}
