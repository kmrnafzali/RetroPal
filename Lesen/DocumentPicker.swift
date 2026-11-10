import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Dateiauswahl, die eine Kopie der Datei liefert. Das ist zuverlässiger als die
/// SwiftUI-Variante, auch in LiveContainer und bei Dateien aus iCloud oder anderen Apps.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = []
        if let epub = UTType("org.idpf.epub-container") { types.append(epub) }
        if let byExtension = UTType(filenameExtension: "epub"), !types.contains(byExtension) { types.append(byExtension) }
        types.append(.zip)
        types.append(.data)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
