using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Nexus.App;

public partial class RemotePage : UserControl
{
    AppState S => AppState.Shared;
    DispatcherTimer? expiry;

    public RemotePage()
    {
        InitializeComponent();
        Enable.IsChecked = S.Settings.RemoteEnabled;
        Loaded += (_, _) => UpdateState();
    }

    void UpdateState()
    {
        var ip = NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a));
        State.Text = S.Remote.IsRunning ? $"Listening on {ip}:{S.Remote.Port} as “{S.Remote.MachineName}” · advertised over Bonjour" : "Off — your iPhone can’t see this PC.";
        PairBox.IsEnabled = S.Remote.IsRunning;
    }

    void Enable_Changed(object sender, RoutedEventArgs e)
    {
        var s = S.Settings;
        if (s.RemoteEnabled == Enable.IsChecked) { UpdateState(); return; }
        s.RemoteEnabled = Enable.IsChecked == true;
        S.SaveSettings(s);
        UpdateState();
    }

    void Pair_Click(object sender, RoutedEventArgs e)
    {
        Code.Text = string.Join(" ", S.Remote.BeginPairing().Chunk(3).Select(c => new string(c)));
        Code.Visibility = CodeHint.Visibility = Visibility.Visible;
        expiry?.Stop();
        expiry = new DispatcherTimer { Interval = TimeSpan.FromMinutes(3) };
        expiry.Tick += (_, _) => { expiry.Stop(); Code.Visibility = CodeHint.Visibility = Visibility.Collapsed; };
        expiry.Start();
    }

    void Revoke_Click(object sender, RoutedEventArgs e) => S.Remote.Revoke(((DeviceRow)((FrameworkElement)sender).Tag).Item.Id);
}
