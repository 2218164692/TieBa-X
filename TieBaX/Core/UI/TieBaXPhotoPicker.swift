import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// iOS 14-compatible image picker. TieBa-X intentionally uses PHPicker rather
/// than PhotosPicker so composing a post has identical behavior on every
/// supported OS version.
struct TieBaPhotoPicker: UIViewControllerRepresentable {
    let maxSelectionCount: Int
    let onPicked: ([Data]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = max(1, maxSelectionCount)
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([Data]) -> Void

        init(onPicked: @escaping ([Data]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            picker.dismiss(animated: true)
            guard results.isEmpty == false else { return }

            let group = DispatchGroup()
            let lock = NSLock()
            var payloads = Array<Data?>(repeating: nil, count: results.count)

            for (index, result) in results.enumerated() {
                group.enter()
                result.itemProvider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    lock.lock()
                    payloads[index] = data
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) { [onPicked] in
                onPicked(payloads.compactMap { $0 })
            }
        }
    }
}
