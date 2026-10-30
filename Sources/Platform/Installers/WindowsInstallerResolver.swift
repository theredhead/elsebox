import AppKit
import WebKit

/// Uses Microsoft's normal download page so its session validation runs in a browser.
/// Only the issued ARM64 URL and published language-specific checksum leave the browser.
@MainActor
final class WindowsInstallerResolver: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private let webView = WKWebView()
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 650),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private var continuation: CheckedContinuation<InstallerImage, Error>?
    private var pendingDownloadURL: URL?
    private var pollTask: Task<Void, Never>?
    private var culture = WindowsCulture.englishUS

    static func resolve(culture: WindowsCulture = .englishUS) async throws -> InstallerImage {
        let resolver = WindowsInstallerResolver()
        resolver.culture = culture
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { resolver.start($0) }
        } onCancel: {
            Task { @MainActor in resolver.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<InstallerImage, Error>) {
        self.continuation = continuation
        window.title = "Get Windows 11 ARM64 Installer from Microsoft"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 650))
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Requesting the \(culture.title) ARM64 ISO from Microsoft. If Microsoft asks for verification, complete it below. The installer will download automatically once its link is ready."
        )
        explanation.frame = NSRect(x: 16, y: 590, width: 828, height: 48)
        explanation.autoresizingMask = [.width, .minYMargin]
        webView.frame = NSRect(x: 0, y: 0, width: 860, height: 580)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        content.addSubview(webView)
        content.addSubview(explanation)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        webView.load(
            URLRequest(url: URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!))
        pollTask = Task { [weak self] in
            // The user may need time to complete a verification on Microsoft's page.
            for _ in 0..<600 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.continuation != nil else { return }
                await self.poll()
            }
            self?.finish(
                .failure(
                    settingsError(
                        "Microsoft did not provide a Windows ARM64 download link. Try again or choose a local ISO in Configuration."
                    )))
        }
    }

    private func poll() async {
        guard webView.url?.host?.lowercased() == "www.microsoft.com" else { return }
        do {
            guard let values = try await webView.evaluateJavaScript(pageScript) as? [String: String],
                let checksum = values["sha256"]
            else { return }
            let link = pendingDownloadURL?.absoluteString ?? values["url"] ?? ""
            guard !link.isEmpty else { return }
            finish(Result { try Self.image(url: link, checksum: checksum) })
        } catch {
            // A navigation can replace the JavaScript context while the page is loading.
        }
    }

    static func image(url: String, checksum: String) throws -> InstallerImage {
        guard let url = URL(string: url), url.scheme == "https",
            let host = url.host?.lowercased(),
            host == "software.download.prss.microsoft.com" || host == "software-download.microsoft.com",
            url.lastPathComponent.lowercased().contains("arm64"),
            url.pathExtension.lowercased() == "iso",
            checksum.count == 64, checksum.allSatisfy({ "0123456789abcdefABCDEF".contains($0) })
        else { throw settingsError("Microsoft returned an invalid Windows ARM64 installer or checksum.") }
        return InstallerImage(url: url, sha256: checksum.lowercased())
    }

    private func finish(_ result: Result<InstallerImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        pollTask?.cancel()
        webView.stopLoading()
        window.orderOut(nil)
        continuation.resume(with: result)
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(CancellationError())) }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        let failure = error as NSError
        if failure.code == NSURLErrorCancelled
            || (failure.domain == "WebKitErrorDomain" && failure.code == 102)
        {
            return
        }
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
            (try? Self.image(url: url.absoluteString, checksum: String(repeating: "0", count: 64))) != nil
        {
            pendingDownloadURL = url
            decisionHandler(.cancel)
            Task { await poll() }
        } else {
            decisionHandler(.allow)
        }
    }

    private var pageScript: String {
        let literal = String(reflecting: culture.microsoftLanguage)
        return Self.scriptTemplate.replacingOccurrences(of: "__LANGUAGE__", with: literal)
    }

    private static let scriptTemplate = #"""
        (() => {
            const language = __LANGUAGE__;
            const visible = e => e && e.getClientRects().length && !e.disabled;
            const edition = document.querySelector('#product-edition');
            const languages = document.querySelector('#product-languages');
            const english = languages && Array.from(languages.options).find(o => {
                try { return JSON.parse(o.value).language === language; } catch { return false; }
            });
            if (english && !window.virtualMacLanguageSubmitted) {
                const button = document.querySelector('#submit-sku');
                if (visible(button)) {
                    window.virtualMacLanguageSubmitted = true;
                    languages.value = english.value;
                    languages.dispatchEvent(new Event('change', { bubbles: true }));
                    button.click();
                }
            } else if (edition && !window.virtualMacEditionSubmitted) {
                const option = Array.from(edition.options).find(o => /arm64/i.test(o.text));
                const button = document.querySelector('#submit-product-edition');
                if (option && visible(button)) {
                    window.virtualMacEditionSubmitted = true;
                    edition.value = option.value;
                    edition.dispatchEvent(new Event('change', { bubbles: true }));
                    button.click();
                }
            }
            const link = Array.from(document.querySelectorAll('a[href]')).find(a => {
                try {
                    const u = new URL(a.href);
                    return /arm64.*\.iso$/i.test(u.pathname) &&
                        ['software.download.prss.microsoft.com', 'software-download.microsoft.com'].includes(u.hostname);
                } catch { return false; }
            });
            const row = Array.from(document.querySelectorAll('tr')).find(r => {
                const cells = r.querySelectorAll('td');
                return cells.length >= 2 && cells[0].textContent.trim().replace(/\s+/g, ' ').toLowerCase() === (language + ' 64-bit').toLowerCase();
            });
            const hash = row && row.querySelectorAll('td')[1].textContent.match(/[0-9a-f]{64}/i);
            return hash ? { url: link ? link.href : "", sha256: hash[0] } : null;
        })()
        """#
}
