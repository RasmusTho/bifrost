import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the note renderer's `ygg://` URLs inside its WKWebView:
/// - `ygg://app/MarkdownWeb/<file>`: the vendored renderer (HTML, JS, CSS, KaTeX fonts)
/// - `ygg://app/font/<face>.ttf`: the bundled Yggdrasil faces
/// - `ygg://vault/<path>`: a file in the active vault (images, audio, video, PDF)
///
/// Nothing else is reachable: the page's CSP admits only `ygg:`, and vault
/// paths that would leave the vault are refused.
final class YggSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ygg"

    private let fileStore: VaultFileStore?
    private let bundle: Bundle
    private var activeTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(fileStore: VaultFileStore?, bundle: Bundle = .main) {
        self.fileStore = fileStore
        self.bundle = bundle
    }

    static var webRootURL: URL? {
        Bundle.main.url(forResource: "MarkdownWeb", withExtension: nil)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        mark(urlSchemeTask, active: true)
        switch host {
        case "app":
            respond(urlSchemeTask, url: url, with: appResource(path))
        case "vault":
            let relativePath = path.joined(separator: "/")
            guard let fileStore else {
                respond(urlSchemeTask, url: url, with: nil)
                return
            }
            Task {
                let data = try? await fileStore.readData(relativePath)
                await MainActor.run { self.respond(urlSchemeTask, url: url, with: data) }
            }
        default:
            respond(urlSchemeTask, url: url, with: nil)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        mark(urlSchemeTask, active: false)
    }

    private func appResource(_ components: [String]) -> Data? {
        guard let first = components.first, !components.contains(".."), !components.contains(".") else { return nil }
        let rest = components.dropFirst()
        switch first {
        case "MarkdownWeb":
            guard let root = Self.webRootURL, !rest.isEmpty else { return nil }
            let url = rest.reduce(root) { $0.appendingPathComponent($1) }
            return try? Data(contentsOf: url)
        case "font":
            guard rest.count == 1, let name = rest.first, name.hasSuffix(".ttf") else { return nil }
            let base = String(name.dropLast(4))
            guard let url = bundle.url(forResource: base, withExtension: "ttf") else { return nil }
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, with data: Data?) {
        guard isActive(task) else { return }
        defer { mark(task, active: false) }
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ]
        )
        let fallback = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response ?? fallback)
        task.didReceive(data)
        task.didFinish()
    }

    private func mark(_ task: WKURLSchemeTask, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            activeTasks.insert(ObjectIdentifier(task))
        } else {
            activeTasks.remove(ObjectIdentifier(task))
        }
    }

    private func isActive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.contains(ObjectIdentifier(task))
    }
}
