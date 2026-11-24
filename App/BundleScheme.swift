import Foundation
import VirtCore
import WebKit

/// Serves Training's screens from inside the app: `virt-app://train/<path>` from the active bundle (BundleStore),
/// with each file's Content-Type, `Cache-Control: no-store` (the app is the cache; a new version must never be mixed
/// with an old one's files), the pages' HTML for `/`, `/try`, `/privacy` and `/terms`, and a 404 for anything that
/// isn't in the manifest (tyleralocke#822; the rules are VirtCore's `BundleManifest.answer`).
///
/// WebKit calls both methods on the main thread and crashes the app if a task is touched after `stop`, so every
/// task still wanted is kept in `live`, and the file's bytes (read off the main thread) are handed over only if the
/// task is still there.
@MainActor final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private var live = Set<ObjectIdentifier>()
    private let files = DispatchQueue(label: "virt.bundle.files", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url, Navigation.isBundled(url), let bundle = BundleStore.shared.active,
              case .file(let file, let type) = bundle.manifest.answer(path: url.path.isEmpty ? "/" : url.path) else {
            return answer(task, url: request.url, status: 404, type: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
        let id = ObjectIdentifier(task)
        live.insert(id)
        let source = bundle.url(of: file)
        let range = request.value(forHTTPHeaderField: "Range")
        let head = request.httpMethod?.uppercased() == "HEAD"
        files.async {
            let data = try? Data(contentsOf: source, options: .mappedIfSafe)
            Task { @MainActor in
                // stopped while the file was being read: WebKit no longer wants it, and must not hear about it
                guard self.live.remove(id) != nil else { return }
                guard let data else {
                    return self.answer(task, url: url, status: 404, type: "text/plain; charset=utf-8", body: Data("Not found".utf8))
                }
                var extra: [String: String] = ["Accept-Ranges": "bytes"]
                var body = data
                var status = 200
                if let r = ByteRange.parse(range, size: data.count) {
                    body = data.subdata(in: r.lowerBound..<(r.upperBound + 1))
                    status = 206
                    extra["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound)/\(data.count)"
                }
                self.answer(task, url: url, status: status, type: type, body: head ? Data() : body, length: body.count, extra: extra)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    /// The whole answer in one go. Only ever for a task WebKit still wants (straight from `start`, or after `live`
    /// said so).
    private func answer(_ task: WKURLSchemeTask, url: URL?, status: Int, type: String, body: Data, length: Int? = nil,
                        extra: [String: String] = [:]) {
        var headers = ["Content-Type": type, "Content-Length": String(length ?? body.count), "Cache-Control": "no-store"]
        headers.merge(extra) { _, new in new }
        let target = url ?? Navigation.bundledHome
        guard let response = HTTPURLResponse(url: target, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
