using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace Cyberlane.KanameLink;

public sealed partial class MainWindow : Window
{
    private readonly CoreClient core = new();
    private readonly bool syntheticPreview;
    private LinkSnapshot snapshot = SyntheticSnapshot.Create();
    private LinkSpace? selectedSpace;
    private LinkDiscussion? selectedDiscussion;

    public MainWindow()
    {
        InitializeComponent();
        syntheticPreview = Environment.GetEnvironmentVariable("KANAME_LINK_SYNTHETIC_PREVIEW") == "1";
        ConfigureWindow();
        PreviewBanner.IsOpen = syntheticPreview;
        Composer.IsEnabled = !syntheticPreview;
        SendButton.IsEnabled = !syntheticPreview;
        Activated += MainWindow_Activated;
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        Activated -= MainWindow_Activated;
        if (!syntheticPreview)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                snapshot = await core.SnapshotAsync(timeout.Token);
            }
            catch (CoreClientException)
            {
                snapshot = new LinkSnapshot("hostOffline", null, [], "LINK-CORE-UNAVAILABLE", null);
                ShowNotice("The signed Link core is unavailable. Reinstall Kaname Link.");
            }
        }
        RenderSnapshot();
    }

    private void ConfigureWindow()
    {
        var handle = WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(handle);
        var appWindow = AppWindow.GetFromWindowId(id);
        appWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));
    }

    private void RenderSnapshot()
    {
        EnrollmentPanel.Visibility = !syntheticPreview && snapshot.Connection == "enrollmentRequired"
            ? Visibility.Visible
            : Visibility.Collapsed;
        ConnectionLabel.Text = ConnectionText(snapshot.Connection);
        ConnectionDot.Fill = (Brush)Application.Current.Resources[
            snapshot.Connection == "hostOnline" ? "KanameSuccessBrush" : "KanameWarningBrush"
        ];
        SpacesList.ItemsSource = snapshot.Spaces;
        SpacesList.DisplayMemberPath = "Name";
        if (snapshot.Spaces.Count > 0) SpacesList.SelectedIndex = 0;
    }

    private async void EnrollButton_Click(object sender, RoutedEventArgs e)
    {
        if (syntheticPreview) return;
        EnrollButton.IsEnabled = false;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            snapshot = await core.EnrollAsync(
                InvitationInput.Text,
                EnrollmentDisplayName.Text,
                timeout.Token
            );
            InvitationInput.Text = string.Empty;
            ShowNotice(snapshot.VerificationCode is { Length: > 0 } code
                ? $"Enrollment requested. Compare {code} with the host before approval."
                : "Enrollment requested. Compare the device verification code with the host before approval.");
            RenderSnapshot();
        }
        catch (CoreClientException)
        {
            ShowNotice("Enrollment was not accepted. Ask the host for a fresh invitation.");
        }
        finally
        {
            EnrollButton.IsEnabled = true;
        }
    }

    private void SpacesList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        selectedSpace = SpacesList.SelectedItem as LinkSpace;
        HostLabel.Text = selectedSpace?.HostName ?? string.Empty;
        SpaceTitle.Text = selectedSpace?.Name ?? "Discussions";
        DiscussionsList.ItemsSource = selectedSpace?.Discussions;
        DiscussionsList.DisplayMemberPath = "Title";
        if (selectedSpace?.Discussions.Count > 0) DiscussionsList.SelectedIndex = 0;
    }

    private void DiscussionsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        selectedDiscussion = DiscussionsList.SelectedItem as LinkDiscussion;
        DiscussionTitle.Text = selectedDiscussion?.Title ?? "No discussion selected";
        DiscussionStatus.Text = selectedDiscussion?.Status ?? string.Empty;
        MessagesList.ItemsSource = selectedDiscussion?.Messages;
    }

    private async void SendButton_Click(object sender, RoutedEventArgs e)
    {
        var body = Composer.Text.Trim();
        if (syntheticPreview || selectedSpace is null || selectedDiscussion is null || body.Length == 0)
        {
            return;
        }
        SendButton.IsEnabled = false;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            await core.SendMessageAsync(selectedSpace.Id, selectedDiscussion.Id, body, timeout.Token);
            Composer.Text = string.Empty;
            snapshot = await core.SnapshotAsync(timeout.Token);
            RenderSnapshot();
        }
        catch (CoreClientException)
        {
            ShowNotice("The message remains queued on this device.");
        }
        finally
        {
            SendButton.IsEnabled = true;
        }
    }

    private void ShowNotice(string message)
    {
        NoticeBar.Message = message;
        NoticeBar.IsOpen = true;
        EnrollmentNoticeBar.Message = message;
        EnrollmentNoticeBar.IsOpen = true;
    }

    private static string ConnectionText(string state) => state switch
    {
        "hostOnline" => "Host online",
        "hostOffline" => "Host offline",
        "revoked" => "Access revoked",
        "enrollmentRequired" => "Enrollment required",
        _ => "Connecting",
    };
}

internal static class SyntheticSnapshot
{
    public static LinkSnapshot Create() => new(
        "hostOnline",
        1_776_990_640_000,
        [
            new LinkSpace(
                "space-synthetic-simplykay",
                "SimplyKay pilot",
                "Justin's Kaname",
                true,
                [
                    new LinkDiscussion(
                        "discussion-wfp-104",
                        "Monthly reporting correction",
                        "Waiting for you",
                        "Review version 2",
                        [
                            new LinkMessage(
                                "message-1",
                                "collaborator",
                                "Kay",
                                "The subscription total should exclude the cancelled account. Could you update the report?",
                                1_776_989_820_000,
                                "Received by host"
                            ),
                            new LinkMessage(
                                "message-2",
                                "host",
                                "Justin",
                                "Version 2 is ready. I corrected the synthetic account total and validated the spreadsheet structure.",
                                1_776_990_540_000,
                                "Published result"
                            ),
                        ]
                    ),
                ]
            ),
        ],
        "SYNTHETIC-PREVIEW",
        null
    );
}
