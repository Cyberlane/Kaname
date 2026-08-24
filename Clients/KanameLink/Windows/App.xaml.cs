using Microsoft.UI.Xaml;

namespace Cyberlane.KanameLink;

public partial class App : Application
{
    private Window? window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window ??= CreateMainWindow();
        window.Activate();
    }

    private MainWindow CreateMainWindow()
    {
        if (window is not null)
        {
            throw new InvalidOperationException("main_window_already_exists");
        }
        var createdWindow = new MainWindow();
        if (createdWindow.Content is null)
        {
            throw new InvalidOperationException("main_window_content_unavailable");
        }
        createdWindow.Closed += (_, _) =>
        {
            if (ReferenceEquals(window, createdWindow))
            {
                window = null;
            }
        };
        return createdWindow;
    }
}
