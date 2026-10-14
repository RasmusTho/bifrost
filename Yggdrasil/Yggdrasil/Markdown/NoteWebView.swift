import QuickLook
import SwiftUI
import WebKit

/// Reads a vault note with the full Obsidian-flavoured renderer: callouts,
/// wikilinks, embeds, properties, tags, highlights, footnotes, tasks, tables,
/// syntax-highlighted code, KaTeX math and Mermaid diagrams.
///
/// The renderer is the vendored, offline bundle in `MarkdownWeb/` (built from
/// `tools/markdown-web`), styled with the same Yggdrasil tokens as the web
/// Companion, so a note reads the same on the web and on iPad. It needs no
/// server: the page only reaches the app bundle and the active vault, through
/// `YggSchemeHandler`.
struct NoteWebView: View {
    let markdown: String
    let notePath: String
    let fileStore: VaultFileStore?
    var onOpenNote: (String, String?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?

    var body: some View {
        if YggSchemeHandler.webRootURL == nil {
            // Renderer bundle missing (should not happen in a built app).
            ScrollView {
                MarkdownRendererView(text: markdown)
                    .padding(YggTheme.Spacing.md)
            }
        } else {
            NoteWebRepresentable(
                markdown: markdown,
                notePath: notePath,
                theme: colorScheme == .light ? "light" : "dark",
                fileStore: fileStore,
                onOpenNote: onOpenNote,
                onOpenExternal: { openURL($0) },
                onOpenAsset: openAsset
            )
            .quickLookPreview($previewURL)
        }
    }

    private func openAsset(_ path: String) {
        guard let fileStore else { return }
        Task { @MainActor in
            guard let data = try? await fileStore.readData(path) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bifrost-preview", isDirectory: true)
                .appendingPathComponent((path as NSString).lastPathComponent)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            previewURL = url
        }
    }
}

private struct NoteWebRepresentable: UIViewRepresentable {
    let markdown: String
    let notePath: String
    let theme: String
    let fileStore: VaultFileStore?
    let onOpenNote: (String, String?) -> Void
    let onOpenExternal: (URL) -> Void
    let onOpenAsset: (String) -> Void

    func makeCoordinator() -> NoteWebCoordinator {
        NoteWebCoordinator(fileStore: fileStore)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: YggSchemeHandler.scheme)
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "bifrost")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        NoteWebCoordinator.removeDropInteractions(from: webView)
        context.coordinator.webView = webView
        context.coordinator.update(from: self)
        if let url = URL(string: "ygg://app/MarkdownWeb/index.html") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: NoteWebCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bifrost")
    }
}

/// Owns the page lifecycle: waits for the bundle to load, resolves the note's
/// link/embed targets against the vault on demand, renders, and routes taps.
@MainActor
final class NoteWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let schemeHandler: YggSchemeHandler
    private let fileStore: VaultFileStore?
    weak var webView: WKWebView?

    private var isReady = false
    private var renderedKey: String?
    private var renderedTheme: String?
    private var current: (markdown: String, notePath: String, theme: String) = ("", "", "dark")
    private var renderTask: Task<Void, Never>?
    private var callbacks: (
        note: (String, String?) -> Void,
        external: (URL) -> Void,
        asset: (String) -> Void
    ) = ({ _, _ in }, { _ in }, { _ in })

    init(fileStore: VaultFileStore?) {
        self.fileStore = fileStore
        self.schemeHandler = YggSchemeHandler(fileStore: fileStore)
    }

    fileprivate func update(from view: NoteWebRepresentable) {
        callbacks = (view.onOpenNote, view.onOpenExternal, view.onOpenAsset)
        current = (view.markdown, view.notePath, view.theme)
        renderIfNeeded()
    }

    private func renderIfNeeded() {
        guard isReady, let webView else { return }
        let key = current.notePath + "\u{0}" + current.markdown
        if key == renderedKey {
            if current.theme != renderedTheme {
                renderedTheme = current.theme
                webView.callAsyncJavaScript(
                    "await window.BifrostMarkdown.setTheme(theme)",
                    arguments: ["theme": current.theme],
                    in: nil,
                    in: .page
                )
            }
            return
        }
        renderedKey = key
        renderedTheme = current.theme
        let snapshot = current
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.render(markdown: snapshot.markdown, notePath: snapshot.notePath, theme: snapshot.theme)
        }
    }

    private func render(markdown: String, notePath: String, theme: String) async {
        guard let webView else { return }
        var resolved: [String: [String: String]] = [:]
        var embedded: [String: String] = [:]
        // Two rounds: the note's own targets, then targets inside embedded notes.
        var pending = [markdown]
        for _ in 0..<2 where !pending.isEmpty {
            var targets: [String] = []
            for source in pending {
                targets += await scan(source, in: webView)
            }
            pending = []
            let unresolved = targets.filter { resolved[$0] == nil }
            guard !unresolved.isEmpty, let fileStore else { break }
            let answers = await fileStore.resolveLinks(unresolved, from: notePath)
            let notesToRead = answers.values.filter { $0.kind == .note && embedded[$0.path] == nil }.map(\.path)
            for (target, answer) in answers {
                resolved[target] = ["path": answer.path, "kind": answer.kind.rawValue]
            }
            if !notesToRead.isEmpty {
                for (path, result) in await fileStore.readMany(Array(Set(notesToRead))) {
                    if case .success(let text) = result {
                        embedded[path] = text
                        pending.append(text)
                    }
                }
            }
            if Task.isCancelled { return }
        }
        if Task.isCancelled { return }
        let payload: [String: Any] = [
            "markdown": markdown,
            "notePath": notePath,
            "theme": theme,
            "resolved": resolved,
            "embedded": embedded
        ]
        _ = try? await webView.callAsyncJavaScript(
            "await window.BifrostMarkdown.render(payload); return true",
            arguments: ["payload": payload],
            contentWorld: .page
        )
    }

    private func scan(_ markdown: String, in webView: WKWebView) async -> [String] {
        let result = try? await webView.callAsyncJavaScript(
            "const s = window.BifrostMarkdown.scan(md); return s.links.concat(s.embeds)",
            arguments: ["md": markdown],
            contentWorld: .page
        )
        return result as? [String] ?? []
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            renderedKey = nil
            renderIfNeeded()
        case "openNote":
            if let path = body["path"] as? String { callbacks.note(path, body["anchor"] as? String) }
        case "openExternal":
            if let raw = body["url"] as? String, let url = URL(string: raw) { callbacks.external(url) }
        case "openAsset":
            if let path = body["path"] as? String { callbacks.asset(path) }
        case "error":
            NSLog("NoteWebView: %@", (body["message"] as? String) ?? "unknown renderer error")
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // The page is a fixed shell; every link is routed through messages.
        let url = navigationAction.request.url
        let isShell = url?.scheme == YggSchemeHandler.scheme && url?.host == "app"
            && url?.path == "/MarkdownWeb/index.html"
        return isShell && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.removeDropInteractions(from: webView)
    }

    /// The reading surface is not a drop target itself: drops (Mimer's drag
    /// promote) belong to the SwiftUI note container around it, so WebKit's
    /// own drop handling must not swallow them.
    static func removeDropInteractions(from view: UIView) {
        for interaction in view.interactions where interaction is UIDropInteraction {
            view.removeInteraction(interaction)
        }
        view.subviews.forEach(removeDropInteractions)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        renderedKey = nil
        webView.reload()
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
