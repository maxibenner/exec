import SwiftUI
import VisionKit
import AVFoundation

struct ScannerView: View {
    let scanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Group {
                if authorized && DataScannerViewController.isSupported && DataScannerViewController.isAvailable && failure == nil {
                    CameraScanner(scanned: scanned, failed: { failure = $0 })
                } else {
                    ContentUnavailableView("Camera Unavailable", systemImage: "qrcode", description: Text(failure ?? "Paste the pairing invitation from the Mac instead, or enable camera access in Settings."))
                }
            }
            .navigationTitle("Scan Pairing Code")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                if DataScannerViewController.isSupported && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    authorized = await AVCaptureDevice.requestAccess(for: .video)
                }
            }
        }
    }
}
private struct CameraScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        let coordinator = context.coordinator
        Task { @MainActor in
            do { try scanner.startScanning() } catch { coordinator.failed("Could not start the camera. Paste a pairing invitation instead.") }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        let failed: (String) -> Void
        var finished = false
        init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) { self.scanned = scanned; self.failed = failed }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failed("Camera scanning became unavailable. Paste a pairing invitation instead.")
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    finished = true; dataScanner.stopScanning(); scanned(text); return
                }
            }
        }
    }
}
