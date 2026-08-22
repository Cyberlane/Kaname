#if os(macOS)
import AppKit
import SwiftUI
@preconcurrency import WebKit

/// Displays only the inert HTML document produced by `MailHTMLReader`.
/// The web view has no persistent website state, no sender JavaScript, and no
/// in-view network navigation. Links are handed to macOS after an explicit click.
@MainActor
struct MailHTMLMessageView: View {
    let html: String
    let loadsRemoteImagesDirectly: Bool

    @State private var measuredHeight: CGFloat = minimumHeight

    private static let minimumHeight: CGFloat = 160
    fileprivate static let maximumHeight: CGFloat = 760

    var body: some View {
        MailHTMLWebView(
            html: html,
            networkPolicy: loadsRemoteImagesDirectly ? .directHTTPSImages : .blockAll,
            measuredHeight: $measuredHeight
        )
            .id(loadsRemoteImagesDirectly)
            .frame(height: min(max(measuredHeight, Self.minimumHeight), Self.maximumHeight))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
    }
}

private enum MailHTMLNetworkPolicy {
    case blockAll
    case directHTTPSImages

    var ruleListIdentifier: String {
        switch self {
        case .blockAll:
            "com.cyberlane.kaname.mail-reader.block-network.v2"
        case .directHTTPSImages:
            "com.cyberlane.kaname.mail-reader.direct-images-only.v1"
        }
    }

    var encodedRules: String {
        switch self {
        case .blockAll:
            """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
            """
        case .directHTTPSImages:
            """
            [
              {"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^https://","resource-type":["image"]},"action":{"type":"block-cookies"}}
            ]
            """
        }
    }
}

@MainActor
private struct MailHTMLWebView: NSViewRepresentable {
    let html: String
    let networkPolicy: MailHTMLNetworkPolicy
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true

        context.coordinator.installNetworkPolicy(on: contentController) { [weak coordinator = context.coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.networkPolicyIsReady = true
            coordinator.load(coordinator.parent.html, in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.networkPolicyIsReady else { return }
        context.coordinator.load(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailHTMLWebView
        var networkPolicyIsReady = false
        private var loadedHTML: String?

        init(parent: MailHTMLWebView) {
            self.parent = parent
        }

        func load(_ html: String, in webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }

        func installNetworkPolicy(
            on contentController: WKUserContentController,
            completion: @escaping @MainActor () -> Void
        ) {
            guard let store = WKContentRuleListStore.default() else {
                completion()
                return
            }
            let identifier = parent.networkPolicy.ruleListIdentifier
            let encodedRules = parent.networkPolicy.encodedRules
            store.lookUpContentRuleList(forIdentifier: identifier) { ruleList, _ in
                if let ruleList {
                    Task { @MainActor in
                        contentController.add(ruleList)
                        completion()
                    }
                    return
                }
                store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encodedRules
                ) { compiledRuleList, _ in
                    Task { @MainActor in
                        if let compiledRuleList {
                            contentController.add(compiledRuleList)
                        }
                        completion()
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                let url = navigationAction.request.url
                let isLocalDocument = url == nil || url?.scheme?.lowercased() == "about"
                decisionHandler(isLocalDocument ? .allow : .cancel)
                return
            }

            if let url = navigationAction.request.url, Self.isSafeExternalLink(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            let measurement = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            webView.evaluateJavaScript(measurement) { [weak self] result, _ in
                guard let height = (result as? NSNumber)?.doubleValue else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    parent.measuredHeight = CGFloat(height)
                }
            }
        }

        private static func isSafeExternalLink(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            switch scheme {
            case "http", "https":
                return url.host?.isEmpty == false
            case "mailto":
                return !url.path.isEmpty
            default:
                return false
            }
        }
    }
}
#endif
