import SwiftUI
import UIKit

/// A UIKit-backed share sheet for SwiftUI.
/// Shares a signed JPEG file by providing its raw Data with a suggested filename.
/// Using Data + filename avoids sandbox permission errors that occur when
/// UIActivityViewController tries to inspect a file:// URL.
struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Read the raw bytes so the share sheet doesn't need sandbox file access.
        // Wrap in a JPEGDataItem so we can provide a suggested filename.
        let item: Any
        if let data = try? Data(contentsOf: fileURL) {
            item = JPEGDataItem(data: data, suggestedName: fileURL.lastPathComponent)
        } else {
            item = fileURL
        }

        let controller = UIActivityViewController(
            activityItems: [item],
            applicationActivities: nil
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Wraps JPEG Data with a suggested filename for UIActivityViewController.
/// Conforms to UIActivityItemSource so AirDrop / Save to Files gets a proper .jpg name.
final class JPEGDataItem: NSObject, UIActivityItemSource {
    let data: Data
    let suggestedName: String

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Write to a temp file so recipients get the correct filename
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        try? data.write(to: tempURL)
        return tempURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "Kibala C2PA Signed Photo"
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "public.jpeg"
    }
}
