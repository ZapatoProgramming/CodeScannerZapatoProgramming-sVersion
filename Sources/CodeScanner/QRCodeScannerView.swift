#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// An enum describing the ways QRCodeScannerView can hit scanning problems.
public enum QRScanError: Error {
    /// The camera could not be accessed.
    case badInput

    /// The camera was not capable of scanning the requested codes.
    case badOutput

    /// Initialization failed.
    case initError(_ error: Error)

    /// The camera permission is denied
    case permissionDenied
}

/// The result from a successful scan: the string that was scanned, the type of data
/// found, and (if available) where the code was on screen at the moment of detection,
/// already converted into the preview layer's coordinate space via
/// `AVCaptureVideoPreviewLayer.transformedMetadataObject(for:)`.
public struct QRScanResult {
    /// The contents of the code.
    public let string: String

    /// The type of code that was matched.
    public let type: AVMetadataObject.ObjectType

    /// The corner coordinates of the scanned code, in the metadata output's own
    /// (untransformed) normalized coordinate space — kept for parity with upstream,
    /// used internally to crop the cosmetic thumbnail.
    public let corners: [CGPoint]

    /// Where the code appeared on screen, in the preview layer's (i.e. this view's)
    /// coordinate space. `nil` if no preview layer was available at detection time.
    public let screenRect: CGRect?
}

/// The operating mode for QRCodeScannerView.
public enum QRScanMode {
    /// Scan exactly one code, then stop.
    case once

    /// Scan each code no more than once.
    case oncePerCode

    /// Keep scanning all codes until dismissed.
    case continuous

    /// Keep scanning all codes - except the ones from the ignored list - until dismissed.
    case continuousExcept(ignoredList: Set<String>)

    /// Scan only when capture button is tapped.
    case manual

    var isManual: Bool {
        switch self {
        case .manual:
            return true
        case .once, .oncePerCode, .continuous, .continuousExcept:
            return false
        }
    }
}

/// A SwiftUI view that scans QR/barcodes and reports what was found. The functional
/// `completion` callback fires the instant a code is decoded — it never waits on the
/// cosmetic thumbnail. The thumbnail (a crop of the frame the code was detected in) is
/// delivered later, independently, via `onThumbnailCaptured`, gated by
/// `thumbnailCaptureArmed` so callers can stop the (comparatively expensive) capture
/// once per scan cycle instead of on every detected frame.
@available(iOS 17.0, *)
public struct QRCodeScannerView: UIViewControllerRepresentable {

    let codeTypes: [AVMetadataObject.ObjectType]
    let scanMode: QRScanMode
    let manualSelect: Bool
    let scanInterval: Double
    let showViewfinder: Bool
    let requiresPhotoOutput: Bool
    var simulatedData = ""
    var isTorchOn: Bool
    var isPaused: Bool
    var isGalleryPresented: Binding<Bool>
    var videoCaptureDevice: AVCaptureDevice?

    /// Functional path — fires synchronously the instant a code is decoded, with zero
    /// added latency. Returns whether the caller accepted this detection as a new
    /// scan. The controller uses that acknowledgement to ensure only the matching
    /// metadata frame can consume the one-shot thumbnail capture.
    var completion: (Result<QRScanResult, QRScanError>) -> Bool

    /// Cosmetic-only path — fires later (after an internal photo capture completes)
    /// with the QR crop and that exact crop's rectangle projected back into preview
    /// coordinates. Optional; callers that don't need a frozen thumbnail can omit it.
    var onThumbnailCaptured: ((UIImage, CGRect?) -> Void)?

    /// Cosmetic-only path — fires if the photo capture genuinely gives up (exhausted
    /// its retries, or was never viable) instead of `onThumbnailCaptured`. This is
    /// what callers should treat as "no thumbnail is coming for this scan," rather
    /// than a fixed timeout racing against a capture that's merely running slow.
    var onThumbnailCaptureFailed: (() -> Void)?

    /// Whether the controller should bother capturing a thumbnail for the *next*
    /// detected code. Callers should flip this to `false` right after consuming one
    /// capture per scan cycle, and back to `true` once fully idle again — this is what
    /// keeps the (relatively expensive) photo capture from firing repeatedly for as
    /// long as the same QR sits in frame during the wait/result window.
    var thumbnailCaptureArmed: Bool

    public init(
        codeTypes: [AVMetadataObject.ObjectType],
        scanMode: QRScanMode = .once,
        manualSelect: Bool = false,
        scanInterval: Double = 2.0,
        showViewfinder: Bool = false,
        requiresPhotoOutput: Bool = true,
        simulatedData: String = "",
        isTorchOn: Bool = false,
        isPaused: Bool = false,
        isGalleryPresented: Binding<Bool> = .constant(false),
        videoCaptureDevice: AVCaptureDevice? = AVCaptureDevice.bestForQRVideo,
        thumbnailCaptureArmed: Bool = true,
        completion: @escaping (Result<QRScanResult, QRScanError>) -> Bool,
        onThumbnailCaptured: ((UIImage, CGRect?) -> Void)? = nil,
        onThumbnailCaptureFailed: (() -> Void)? = nil
    ) {
        self.codeTypes = codeTypes
        self.scanMode = scanMode
        self.manualSelect = manualSelect
        self.showViewfinder = showViewfinder
        self.requiresPhotoOutput = requiresPhotoOutput
        self.scanInterval = scanInterval
        self.simulatedData = simulatedData
        self.isTorchOn = isTorchOn
        self.isPaused = isPaused
        self.isGalleryPresented = isGalleryPresented
        self.videoCaptureDevice = videoCaptureDevice
        self.thumbnailCaptureArmed = thumbnailCaptureArmed
        self.completion = completion
        self.onThumbnailCaptured = onThumbnailCaptured
        self.onThumbnailCaptureFailed = onThumbnailCaptureFailed
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        return ScannerViewController(showViewfinder: showViewfinder, parentView: self)
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let scannerViewController = uiViewController as? ScannerViewController else {
            return
        }

        scannerViewController.parentView = self
        scannerViewController.updateViewController(
            isTorchOn: isTorchOn,
            isGalleryPresented: isGalleryPresented.wrappedValue,
            isManualCapture: scanMode.isManual,
            isManualSelect: manualSelect
        )
    }
}

// MARK: - AVCaptureDevice

extension AVCaptureDevice {
    /// This returns the Ultra Wide Camera on capable devices and the default Camera for Video otherwise.
    public static var bestForQRVideo: AVCaptureDevice? {
        let deviceHasUltraWideCamera = !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back).devices.isEmpty
        return deviceHasUltraWideCamera ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : AVCaptureDevice.default(for: .video)
    }
}
#endif
