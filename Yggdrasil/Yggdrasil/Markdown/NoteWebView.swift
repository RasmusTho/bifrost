import QuickLook
import SwiftUI
import UniformTypeIdentifiers
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
    /// Heading or block anchor to scroll to once rendered (`#Heading`, `#^id`).
    var anchor: String?
    var onOpenNote: (String, String?) -> Void = { _, _ in }
    /// Accepts drops onto the reading surface (Mimer's drag-promote). WebKit
    /// would otherwise claim plain-text drops itself, so the page sits under a
    /// drop-only overlay when this is set.
    var onDrop: (([NSItemProvider]) -> Bool)?

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
                anchor: anchor,
                theme: colorScheme == .light ? "light" : "dark",
                fileStore: fileStore,
                onOpenNote: onOpenNote,
                onOpenExternal: { openURL($0) },
                onOpenAsset: openAsset,
                onDrop: onDrop
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
    let anchor: String?
    let theme: String
    let fileStore: VaultFileStore?
    let onOpenNote: (String, String?) -> Void
    let onOpenExternal: (URL) -> Void
    let onOpenAsset: (String) -> Void
    let onDrop: (([NSItemProvider]) -> Bool)?

    func makeCoordinator() -> NoteWebCoordinator {
        NoteWebCoordinator(fileStore: fileStore)
    }

    func makeUIView(context: Context) -> NoteWebContainerView {
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
        webView.accessibilityIdentifier = "mimer.note.renderer"
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        context.coordinator.webView = webView
        context.coordinator.update(from: self)
        if let url = URL(string: "ygg://app/MarkdownWeb/index.html") {
            webView.load(URLRequest(url: url))
        }
        let container = NoteWebContainerView(webView: webView)
        container.dropOverlay.addInteraction(UIDropInteraction(delegate: context.coordinator))
        container.dropOverlay.isHidden = onDrop == nil
        return container
    }

    func updateUIView(_ container: NoteWebContainerView, context: Context) {
        container.dropOverlay.isHidden = onDrop == nil
        context.coordinator.update(from: self)
    }

    static func dismantleUIView(_ container: NoteWebContainerView, coordinator: NoteWebCoordinator) {
        container.webView.configuration.userContentController.removeScriptMessageHandler(forName: "bifrost")
    }
}

/// Hosts the page plus a drop-only overlay above it.
final class NoteWebContainerView: UIView {
    let webView: WKWebView
    let dropOverlay = DropOnlyOverlayView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = .clear
        for view in [webView, dropOverlay] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Transparent to touches, scrolling and accessibility; visible only to drag
/// sessions, so drops land on the note instead of inside WebKit.
final class DropOnlyOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let event, NSStringFromClass(type(of: event)).contains("Drag") else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Owns the page lifecycle: waits for the bundle to load, resolves the note's
/// link/embed targets against the vault on demand, renders, and routes taps.
@MainActor
final class NoteWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIDropInteractionDelegate {
    let schemeHandler: YggSchemeHandler
    private let fileStore: VaultFileStore?
    weak var webView: WKWebView?

    private var isReady = false
    private var renderedKey: String?
    private var renderedTheme: String?
    private var current = RenderRequest(markdown: "", notePath: "", anchor: nil, theme: "dark")
    /// The last payload sent to the page, re-sent with a new theme so Mermaid
    /// (which bakes colours into its SVG) redraws without re-resolving links.
    private var lastPayload: [String: Any]?
    private var renderTask: Task<Void, Never>?
    private var onOpenNote: (String, String?) -> Void = { _, _ in }
    private var onOpenExternal: (URL) -> Void = { _ in }
    private var onOpenAsset: (String) -> Void = { _ in }
    private var onDrop: (([NSItemProvider]) -> Bool)?

    private struct RenderRequest {
        let markdown: String
        let notePath: String
        let anchor: String?
        let theme: String
    }

    /// A note's targets, kept apart: only embeds need their note text read.
    private struct ScanResult: Decodable {
        let links: [String]
        let embeds: [String]
    }

    init(fileStore: VaultFileStore?) {
        self.fileStore = fileStore
        self.schemeHandler = YggSchemeHandler(fileStore: fileStore)
    }

    fileprivate func update(from view: NoteWebRepresentable) {
        onOpenNote = view.onOpenNote
        onOpenExternal = view.onOpenExternal
        onOpenAsset = view.onOpenAsset
        onDrop = view.onDrop
        current = RenderRequest(
            markdown: view.markdown,
            notePath: view.notePath,
            anchor: view.anchor,
            theme: view.theme
        )
        renderIfNeeded()
    }

    private func renderIfNeeded() {
        guard isReady, let webView else { return }
        let key = [current.notePath, current.anchor ?? "", current.markdown].joined(separator: "\u{0}")
        if key == renderedKey {
            if current.theme != renderedTheme {
                renderedTheme = current.theme
                rerender(theme: current.theme, in: webView)
            }
            return
        }
        renderedKey = key
        renderedTheme = current.theme
        webView.accessibilityValue = "rendering:\(current.notePath)"
        let snapshot = current
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.render(snapshot)
        }
    }

    private func render(_ request: RenderRequest) async {
        guard let webView else { return }
        let targets = await resolveTargets(of: request.markdown, notePath: request.notePath, in: webView)
        if Task.isCancelled { return }
        var payload: [String: Any] = [
            "markdown": request.markdown,
            "notePath": request.notePath,
            "theme": request.theme,
            "resolved": targets.bySource[request.notePath] ?? [:],
            "resolvedBySource": targets.bySource,
            "embedded": targets.embedded
        ]
        if let anchor = request.anchor { payload["anchor"] = anchor }
        lastPayload = payload
        await send(payload, theme: request.theme, in: webView)
    }

    /// Theme flips re-render the cached payload: CSS follows `data-theme`, but
    /// Mermaid diagrams must be redrawn with the new palette.
    private func rerender(theme: String, in webView: WKWebView) {
        guard var payload = lastPayload else { return }
        payload.removeValue(forKey: "anchor") // keep the reader's scroll position
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            await self?.send(payload, theme: theme, in: webView)
        }
    }

    private func send(_ payload: [String: Any], theme: String, in webView: WKWebView) async {
        var payload = payload
        payload["theme"] = theme
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let literal = String(data: json, encoding: .utf8) else { return }
        _ = await Self.run("window.BifrostMarkdown.render(\(literal)), true", in: webView)
    }

    /// Resolves link/embed targets on demand, each against the note it is
    /// written in, and reads embedded notes, in two rounds: the note's own
    /// targets, then targets inside the notes it embeds.
    private func resolveTargets(
        of markdown: String,
        notePath: String,
        in webView: WKWebView
    ) async -> (bySource: [String: [String: [String: String]]], embedded: [String: String]) {
        var bySource: [String: [String: [String: String]]] = [:]
        var embedded: [String: String] = [:]
        var pending = [(path: notePath, text: markdown)]
        for _ in 0..<2 where !pending.isEmpty {
            guard let fileStore else { break }
            var next: [(path: String, text: String)] = []
            for source in pending where bySource[source.path] == nil {
                guard let scanned = await scan(source.text, in: webView) else { continue }
                let answers = await fileStore.resolveLinks(scanned.links + scanned.embeds, from: source.path)
                bySource[source.path] = answers.mapValues { ["path": $0.path, "kind": $0.kind.rawValue] }
                let notesToRead = Set(scanned.embeds.compactMap { answers[$0] }
                    .filter { $0.kind == .note && embedded[$0.path] == nil }
                    .map(\.path))
                for (path, result) in await fileStore.readMany(Array(notesToRead)) {
                    if case .success(let text) = result {
                        embedded[path] = text
                        next.append((path, text))
                    }
                }
                if Task.isCancelled { return (bySource, embedded) }
            }
            pending = next
        }
        return (bySource, embedded)
    }

    private func scan(_ markdown: String, in webView: WKWebView) async -> ScanResult? {
        let script = "JSON.stringify(window.BifrostMarkdown.scan(\(Self.literal(markdown))))"
        guard let result = await Self.run(script, in: webView) as? String,
              let data = result.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScanResult.self, from: data)
    }

    /// JSON-encodes a string as a JavaScript literal.
    private static func literal(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// Runs page script through the plain Objective-C `evaluateJavaScript`
    /// entry point. The Swift-overlay conveniences (`callAsyncJavaScript`,
    /// Result-based variants) link `libswiftWebKit`, which newer simulator and
    /// OS runtimes no longer ship, so the app would fail to launch there.
    private static func run(_ script: String, in webView: WKWebView) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { NSLog("NoteWebView script error: %@", error.localizedDescription) }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            renderedKey = nil
            renderIfNeeded()
        case "rendered":
            // The bundled page posts this only after it has inserted the
            // rendered note DOM (and finished any Mermaid work). Expose that
            // boundary so UI automation can synchronize before querying the
            // WebKit accessibility tree.
            webView?.accessibilityValue = "rendered:\(current.notePath)"
        case "openNote":
            if let path = body["path"] as? String { onOpenNote(path, body["anchor"] as? String) }
        case "openExternal":
            if let raw = body["url"] as? String, let url = URL(string: raw) { onOpenExternal(url) }
        case "openAsset":
            if let path = body["path"] as? String { onOpenAsset(path) }
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

    // MARK: UIDropInteractionDelegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        onDrop != nil && session.hasItemsConforming(toTypeIdentifiers: [UTType.plainText.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        _ = onDrop?(session.items.map(\.itemProvider))
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
