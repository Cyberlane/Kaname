#if os(macOS)
import AppKit
@preconcurrency import QuickLookUI

@MainActor
final class WorkflowArtifactPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = WorkflowArtifactPreviewController()
    private var urls: [URL] = []

    func present(_ urls: [URL], selectedIndex: Int = 0) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else {
            if let first = urls.first {
                _ = NSWorkspace.shared.open(first)
            }
            return
        }
        panel.dataSource = self
        panel.currentPreviewItemIndex = min(max(0, selectedIndex), max(0, urls.count - 1))
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        urls[index] as NSURL
    }
}
#endif
