import AppKit
import UniformTypeIdentifiers

/// AppKit file panels used by the native Simulator tools inspector.
@MainActor
public final class NativeSimulatorFilePicker: SimulatorFilePicking {
    /// Creates the default native file picker.
    public init() {}

    /// Chooses an `.app` bundle or `.ipa` archive to install.
    public func chooseApplication() async -> URL? {
        await openFile(
            types: [.applicationBundle, UTType(filenameExtension: "ipa")].compactMap { $0 },
            allowsMultipleSelection: false
        ).first
    }

    /// Chooses photos, videos, contacts, or Live Photo resources to import.
    public func chooseMedia() async -> [URL] {
        await openFile(
            types: [.image, .movie, .vCard],
            allowsMultipleSelection: true
        )
    }

    /// Chooses an Apple Push Notification JSON payload.
    public func choosePushPayload() async -> URL? {
        await openFile(types: [.json], allowsMultipleSelection: false).first
    }

    /// Chooses an image or video source for experimental camera injection.
    public func chooseCameraSource() async -> URL? {
        await openFile(types: [.image, .movie], allowsMultipleSelection: false).first
    }

    /// Chooses where to save a Simulator screenshot.
    /// - Parameter fileExtension: The selected image format's extension.
    public func chooseScreenshotDestination(fileExtension: String) async -> URL? {
        await saveFile(defaultName: String(
            localized: simulatorStrings.screenshotFilename(fileExtension)
        ))
    }

    /// Chooses where to save a Simulator video recording.
    public func chooseVideoDestination() async -> URL? {
        await saveFile(defaultName: String(localized: simulatorStrings.videoFilename))
    }

    private func openFile(
        types: [UTType],
        allowsMultipleSelection: Bool
    ) async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = types.contains(.applicationBundle)
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = types
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { response in
                    // cmux-rbf: read the selection on the main actor. This target is
                    // .swiftLanguageMode(.v6), and the macOS 26 SDK marks
                    // `NSOpenPanel.begin`'s completion handler @Sendable, so touching the
                    // main-actor-isolated `urls` inside it is an error here. AppKit runs
                    // this handler on the main thread, so assuming isolation is sound.
                    // Upstream compiles as-is against an SDK without that annotation.
                    // Reject this hunk on upstream sync.
                    let urls = MainActor.assumeIsolated { panel.urls }
                    continuation.resume(returning: response == .OK ? urls : [])
                }
            }
        } onCancel: {
            Task { @MainActor [weak panel] in
                panel?.cancel(nil)
            }
        }
    }

    private func saveFile(defaultName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { response in
                    // cmux-rbf: same main-actor read as the open-panel case above.
                    // Reject this hunk on upstream sync.
                    let url = MainActor.assumeIsolated { panel.url }
                    continuation.resume(returning: response == .OK ? url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak panel] in
                panel?.cancel(nil)
            }
        }
    }
}
