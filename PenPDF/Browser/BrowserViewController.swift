import PDFKit
import UIKit
import UniformTypeIdentifiers

/// The Files-app browser, used as the app's root (FR-1). Gives us "Open With"
/// from anywhere in iOS, iCloud Drive, external drives and tags for free.
final class BrowserViewController: UIDocumentBrowserViewController,
                                   UIDocumentBrowserViewControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        allowsDocumentCreation = false
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = false
    }

    // MARK: - UIDocumentBrowserViewControllerDelegate

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didPickDocumentsAt documentURLs: [URL]
    ) {
        guard let url = documentURLs.first else { return }
        openDocument(at: url)
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        failedToImportDocumentAt documentURL: URL,
        error: Error?
    ) {
        presentFailure("Couldn't open \(documentURL.lastPathComponent).")
    }

    func documentBrowser(
        _ controller: UIDocumentBrowserViewController,
        didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void
    ) {
        // Document creation is disabled (allowsDocumentCreation = false); this
        // delegate method still must be answered.
        importHandler(nil, .none)
    }

    // MARK: - Opening

    /// §5.4 "Open" steps 1–3.
    func openDocument(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()

        guard let document = PDFDocument(url: url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            LastDocument.forget()
            presentFailure("\(url.lastPathComponent) isn't a readable PDF.")
            return
        }

        LastDocument.remember(url)

        func presentReader() {
            let reader = ReaderViewController(fileURL: url, document: document, securityScoped: scoped)
            let navigation = UINavigationController(rootViewController: reader)
            navigation.modalPresentationStyle = .fullScreen
            present(navigation, animated: true)
        }

        if presentedViewController != nil {
            dismiss(animated: false) {
                presentReader()
            }
        } else {
            presentReader()
        }
    }

    private func presentFailure(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (presentedViewController ?? self).present(alert, animated: true)
    }
}
