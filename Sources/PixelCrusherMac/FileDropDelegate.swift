import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FileDropDelegate: DropDelegate {
    let model: AppViewModel
    let markDropTargeted: (DropValidationState) -> Void
    let clearDropTargeting: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropEntered(info: DropInfo) {
        markDropTargeted(dropValidation(for: info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        markDropTargeted(dropValidation(for: info))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        _ = info
        clearDropTargeting()
    }

    func performDrop(info: DropInfo) -> Bool {
        clearDropTargeting()
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        guard !providers.isEmpty else {
            return false
        }
        return model.handleDrop(providers: providers)
    }

    private func dropValidation(for info: DropInfo) -> DropValidationState {
        let hasFileURLs = info.hasItemsConforming(to: [UTType.fileURL.identifier])
        guard hasFileURLs else {
            return .idle
        }

        let hasSupportedImages = info.hasItemsConforming(to: AppViewModel.supportedImageTypeIdentifiers)
        let hasFolder = info.hasItemsConforming(to: AppViewModel.folderTypeIdentifiers)

        if hasSupportedImages || hasFolder {
            return .supported
        }

        return .unsupported
    }
}
