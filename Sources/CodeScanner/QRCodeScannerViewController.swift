#if os(iOS)
@preconcurrency import AVFoundation
import UIKit
import Vision

/// Owns the capture session's blocking start/stop operations on one serial queue.
/// AVCaptureSession is not Sendable, so the wrapper's unchecked conformance is the
/// narrow synchronization boundary: the session never escapes into arbitrary
/// `@Sendable` closures, and all lifecycle operations run in order on `queue`.
nonisolated private final class QRCaptureSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(
        label: "qr-scanner.capture-session",
        qos: .userInitiated
    )

    func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

@available(iOS 17.0, *)
extension QRCodeScannerView {

    public final class ScannerViewController: UIViewController, UINavigationControllerDelegate {
        private struct ThumbnailCaptureContext {
            let payload: String
            let screenRect: CGRect?
            let previewBounds: CGRect
        }

        private let photoOutput = AVCapturePhotoOutput()
        private var isCapturing = false
        private let maximumThumbnailCaptureAttempts = 2
        private var thumbnailCaptureAttempt = 0
        /// Information from the accepted metadata frame. The payload lets us locate the
        /// same QR again in the actual still photo, avoiding the incorrect assumption
        /// that metadata/video coordinates map directly to still-photo pixels.
        private var pendingThumbnailContext: ThumbnailCaptureContext?
        /// Self-contained mirror of `parentView.thumbnailCaptureArmed`, closed the
        /// instant a capture is kicked off. `parentView.thumbnailCaptureArmed` only
        /// updates through a SwiftUI state round-trip (state change → body re-render →
        /// updateUIViewController), which is NOT synchronous with this delegate — at
        /// 15-30 detections/sec, several frames can fire before that round-trip lands,
        /// each re-triggering a capture and overwriting the "frozen" thumbnail with a
        /// fresh one (looks like a live feed instead of a freeze). Closing this flag
        /// synchronously, in the same call that decides to capture, is what actually
        /// enforces "at most once per cycle." Re-arming (the caller starting a new cycle
        /// started) is fine to pick up on the next SwiftUI update, since there's no
        /// redundant-work risk in that direction.
        private var isThumbnailArmed = true
        private var lastKnownThumbnailCaptureArmed = true
        private var rotationCoordinator: AnyObject?
        var parentView: QRCodeScannerView!
        var codesFound = Set<String>()
        var didFinishScanning = false
        var lastTime = Date(timeIntervalSince1970: 0)
        private let showViewfinder: Bool

        let fallbackVideoCaptureDevice = AVCaptureDevice.default(for: .video)

        private var isGalleryShowing: Bool = false {
            didSet {
                if parentView.isGalleryPresented.wrappedValue != isGalleryShowing {
                    parentView.isGalleryPresented.wrappedValue = isGalleryShowing
                }
            }
        }

        init(showViewfinder: Bool = false, parentView: QRCodeScannerView) {
            self.parentView = parentView
            self.showViewfinder = showViewfinder
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            self.showViewfinder = false
            super.init(coder: coder)
        }

        private func startThumbnailCapture(
            payload: String,
            screenRect: CGRect?,
            previewBounds: CGRect
        ) {
            pendingThumbnailContext = ThumbnailCaptureContext(
                payload: payload,
                screenRect: screenRect,
                previewBounds: previewBounds
            )
            thumbnailCaptureAttempt = 0
            capturePendingThumbnail()
        }

        private func capturePendingThumbnail() {
            guard pendingThumbnailContext != nil else { return }
            thumbnailCaptureAttempt += 1
            isCapturing = true
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }

        private func retryOrFinishThumbnailCapture(reason: String) {
            isCapturing = false

            guard thumbnailCaptureAttempt < maximumThumbnailCaptureAttempts,
                  pendingThumbnailContext != nil else {
                print("⚠️ Thumbnail capture failed after \(thumbnailCaptureAttempt) attempt(s): \(reason)")
                pendingThumbnailContext = nil
                return
            }

            print("⚠️ Thumbnail capture failed; retrying once: \(reason)")
            capturePendingThumbnail()
        }

        /// Detects the accepted payload in the still photo itself. This is the primary
        /// crop source because it reflects the QR's position at the actual exposure
        /// time and is already expressed relative to the photo being cropped.
        private func detectedQRCodeRect(
            in image: CGImage,
            matching payload: String
        ) -> CGRect? {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]

            do {
                try VNImageRequestHandler(
                    cgImage: image,
                    orientation: .up,
                    options: [:]
                ).perform([request])
            } catch {
                print("⚠️ Still-photo QR detection failed: \(error.localizedDescription)")
                return nil
            }

            guard let observation = request.results?.first(where: {
                $0.payloadStringValue == payload
            }) else {
                return nil
            }

            // Vision uses normalized coordinates with a bottom-left origin; CGImage
            // cropping uses pixel coordinates with a top-left origin.
            let bounds = observation.boundingBox
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            return CGRect(
                x: bounds.minX * width,
                y: (1 - bounds.maxY) * height,
                width: bounds.width * width,
                height: bounds.height * height
            )
        }

        /// Fallback for a still photo where Vision cannot decode the QR. Replays the
        /// preview layer's `.resizeAspectFill` transform in reverse, which correctly
        /// accounts for the crop introduced by differing preview/photo aspect ratios.
        private func previewMappedRect(
            context: ThumbnailCaptureContext,
            imageSize: CGSize
        ) -> CGRect? {
            guard let screenRect = context.screenRect,
                  context.previewBounds.width > 0,
                  context.previewBounds.height > 0,
                  imageSize.width > 0,
                  imageSize.height > 0 else {
                return nil
            }

            let previewSize = context.previewBounds.size
            let scale = max(
                previewSize.width / imageSize.width,
                previewSize.height / imageSize.height
            )
            let displayedSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            let displayedOrigin = CGPoint(
                x: (previewSize.width - displayedSize.width) / 2,
                y: (previewSize.height - displayedSize.height) / 2
            )
            let localRect = screenRect.offsetBy(
                dx: -context.previewBounds.minX,
                dy: -context.previewBounds.minY
            )

            return CGRect(
                x: (localRect.minX - displayedOrigin.x) / scale,
                y: (localRect.minY - displayedOrigin.y) / scale,
                width: localRect.width / scale,
                height: localRect.height / scale
            )
        }

        private func paddedCropRect(_ rect: CGRect, within fullRect: CGRect) -> CGRect {
            let padded = rect.insetBy(
                dx: -rect.width * 0.12,
                dy: -rect.height * 0.12
            )
            return padded.integral.intersection(fullRect)
        }

        func openGallery() {
            isGalleryShowing = true
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            imagePicker.presentationController?.delegate = self
            present(imagePicker, animated: true, completion: nil)
        }

        @objc func openGalleryFromButton(_ sender: UIButton) {
            openGallery()
        }

        #if targetEnvironment(simulator)
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = true
            view.backgroundColor = .black

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.textColor = .white
            label.text = "Simulador: no hay cámara disponible.\nToca la pantalla para simular un escaneo."
            label.textAlignment = .center

            let button = UIButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle("Select a custom image", for: .normal)
            button.setTitleColor(UIColor.systemBlue, for: .normal)
            button.setTitleColor(UIColor.gray, for: .highlighted)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)

            let stackView = UIStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.axis = .vertical
            stackView.spacing = 50
            stackView.addArrangedSubview(label)
            stackView.addArrangedSubview(button)

            view.addSubview(stackView)

            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 50),
                stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            simulateTap()
        }

        private func simulateTap() {
            // Simulate a detection roughly where the static resting frame sits, so the
            // capture animation has a plausible target rect to snap out to.
            let syntheticRect = view.bounds.insetBy(dx: view.bounds.width * 0.22, dy: view.bounds.height * 0.32)

            let wasAccepted = found(QRScanResult(
                string: parentView.simulatedData,
                type: parentView.codeTypes.first ?? .qr,
                corners: [],
                screenRect: syntheticRect
            ))

            guard wasAccepted, parentView.thumbnailCaptureArmed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.parentView.onThumbnailCaptured?(Self.makeSimulatedThumbnail(size: syntheticRect.size))
            }
        }

        private static func makeSimulatedThumbnail(size: CGSize) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.withAlphaComponent(0.85).setStroke()
                let inset = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.15, dy: size.height * 0.15)
                let path = UIBezierPath(rect: inset)
                path.lineWidth = 6
                path.stroke()
            }
        }

        #else

        private var sessionRunner: QRCaptureSessionRunner?
        var captureSession: AVCaptureSession? { sessionRunner?.session }
        var previewLayer: AVCaptureVideoPreviewLayer!

        // Decorative assets are optional. A missing image disables the viewfinder or
        // leaves the manual capture button without a custom background.
        private lazy var viewFinder: UIImageView? = {
            guard let image = UIImage(named: "viewfinder", in: nil, with: nil) else {
                return nil
            }
            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            return imageView
        }()

        private lazy var manualCaptureButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(named: "capture", in: nil, with: nil)
            button.setBackgroundImage(image, for: .normal)
            button.addTarget(self, action: #selector(manualCapturePressed), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()

        private lazy var manualSelectButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(systemName: "photo.on.rectangle")
            let background = UIImage(systemName: "capsule.fill")?.withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
            button.setImage(image, for: .normal)
            button.setBackgroundImage(background, for: .normal)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()

        override func viewDidLoad() {
            super.viewDidLoad()
            self.addOrientationDidChangeObserver()
            self.setBackgroundColor()
            self.handleCameraPermission()
        }

        override func viewWillLayoutSubviews() {
            previewLayer?.frame = view.layer.bounds
            updateOrientation()
        }

        @objc func updateOrientation() {
            guard previewLayer != nil,
                  let device = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice else {
                return
            }

            let coordinator: AVCaptureDevice.RotationCoordinator
            if let existing = rotationCoordinator as? AVCaptureDevice.RotationCoordinator,
               existing.device === device {
                coordinator = existing
            } else {
                coordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: previewLayer
                )
                rotationCoordinator = coordinator
            }

            let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            for connection in captureSession?.connections ?? []
                where connection.isVideoRotationAngleSupported(captureAngle) {
                connection.videoRotationAngle = captureAngle
            }

            let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            if let previewConnection = previewLayer.connection,
               previewConnection.isVideoRotationAngleSupported(previewAngle) {
                previewConnection.videoRotationAngle = previewAngle
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateOrientation()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            setupSession()
        }

        private func setupSession() {
            guard let captureSession else {
                return
            }

            if previewLayer == nil {
                previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            }

            previewLayer.frame = view.layer.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
            addViewFinder()
            // Session setup can finish after viewDidAppear's own updateOrientation()
            // call (e.g. while waiting on a first-time permission prompt) — make sure
            // every connection created here still gets the right orientation applied.
            updateOrientation()

            reset()

            sessionRunner?.start()
        }

        private func handleCameraPermission() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .restricted:
                    break
                case .denied:
                    self.didFail(reason: .permissionDenied)
                case .notDetermined:
                    self.requestCameraAccess()
                case .authorized:
                    self.setupCaptureDevice()
                    self.setupSession()

                default:
                    break
            }
        }

        private func requestCameraAccess() {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard status else {
                        self.didFail(reason: .permissionDenied)
                        return
                    }
                    self.setupCaptureDevice()
                    self.setupSession()
                }
            }
        }

        private func addOrientationDidChangeObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateOrientation),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
        }

        private func setBackgroundColor(_ color: UIColor = .black) {
            view.backgroundColor = color
        }

        private func setupCaptureDevice() {
            let runner = QRCaptureSessionRunner()
            sessionRunner = runner
            let captureSession = runner.session

            guard let videoCaptureDevice = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice else {
                return
            }

            let videoInput: AVCaptureDeviceInput

            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            } catch {
                didFail(reason: .initError(error))
                return
            }

            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                didFail(reason: .badInput)
                return
            }
            let metadataOutput = AVCaptureMetadataOutput()

            guard captureSession.canAddOutput(metadataOutput) else {
                didFail(reason: .badOutput)
                return
            }

            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = parentView.codeTypes

            if parentView.requiresPhotoOutput {
                guard captureSession.canAddOutput(photoOutput) else {
                    didFail(reason: .badOutput)
                    return
                }
                captureSession.addOutput(photoOutput)
            }
        }

        private func addViewFinder() {
            guard showViewfinder, let imageView = viewFinder else { return }

            view.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 200),
                imageView.heightAnchor.constraint(equalToConstant: 200),
            ])
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)

            sessionRunner?.stop()

            NotificationCenter.default.removeObserver(self)
        }

        override var prefersStatusBarHidden: Bool {
            true
        }

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            .all
        }

        /** Touch the screen for autofocus */
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.view == view,
                  let touchPoint = touches.first,
                  let device = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice,
                  device.isFocusPointOfInterestSupported
            else { return }

            let videoView = view
            let screenSize = videoView!.bounds.size
            let xPoint = touchPoint.location(in: videoView).y / screenSize.height
            let yPoint = 1.0 - touchPoint.location(in: videoView).x / screenSize.width
            let focusPoint = CGPoint(x: xPoint, y: yPoint)

            do {
                try device.lockForConfiguration()
            } catch {
                return
            }

            device.focusPointOfInterest = focusPoint
            device.focusMode = .continuousAutoFocus
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
            device.unlockForConfiguration()
        }

        @objc func manualCapturePressed(_ sender: Any?) {
            self.readyManualCapture()
        }

        func showManualCaptureButton(_ isManualCapture: Bool) {
            if manualCaptureButton.superview == nil {
                view.addSubview(manualCaptureButton)
                NSLayoutConstraint.activate([
                    manualCaptureButton.heightAnchor.constraint(equalToConstant: 60),
                    manualCaptureButton.widthAnchor.constraint(equalTo: manualCaptureButton.heightAnchor),
                    view.centerXAnchor.constraint(equalTo: manualCaptureButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualCaptureButton.bottomAnchor, constant: 32)
                ])
            }

            view.bringSubviewToFront(manualCaptureButton)
            manualCaptureButton.isHidden = !isManualCapture
        }

        func showManualSelectButton(_ isManualSelect: Bool) {
            if manualSelectButton.superview == nil {
                view.addSubview(manualSelectButton)
                NSLayoutConstraint.activate([
                    manualSelectButton.heightAnchor.constraint(equalToConstant: 50),
                    manualSelectButton.widthAnchor.constraint(equalToConstant: 60),
                    view.centerXAnchor.constraint(equalTo: manualSelectButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualSelectButton.bottomAnchor, constant: 32)
                ])
            }

            view.bringSubviewToFront(manualSelectButton)
            manualSelectButton.isHidden = !isManualSelect
        }
        #endif

        func updateViewController(isTorchOn: Bool, isGalleryPresented: Bool, isManualCapture: Bool, isManualSelect: Bool) {
            // Pick up re-arming from the caller (false → true transition only — see
            // isThumbnailArmed's doc comment for why disarming can't go through here).
            if parentView.thumbnailCaptureArmed != lastKnownThumbnailCaptureArmed {
                lastKnownThumbnailCaptureArmed = parentView.thumbnailCaptureArmed
                if parentView.thumbnailCaptureArmed {
                    isThumbnailArmed = true
                }
            }

            guard let videoCaptureDevice = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice else {
                return
            }

            if videoCaptureDevice.hasTorch {
                try? videoCaptureDevice.lockForConfiguration()
                videoCaptureDevice.torchMode = isTorchOn ? .on : .off
                videoCaptureDevice.unlockForConfiguration()
            }

            if isGalleryPresented, !isGalleryShowing {
                openGallery()
            }

            #if !targetEnvironment(simulator)
            showManualCaptureButton(isManualCapture)
            showManualSelectButton(isManualSelect)
            #endif
        }

        func reset() {
            codesFound.removeAll()
            didFinishScanning = false
            lastTime = Date(timeIntervalSince1970: 0)
        }

        func readyManualCapture() {
            guard parentView.scanMode.isManual else { return }
            self.reset()
            lastTime = Date()
        }

        var isPastScanInterval: Bool {
            Date().timeIntervalSince(lastTime) >= parentView.scanInterval
        }

        var isWithinManualCaptureInterval: Bool {
            Date().timeIntervalSince(lastTime) <= 0.5
        }

        @discardableResult
        func found(_ result: QRScanResult) -> Bool {
            lastTime = Date()
            // No vibration here deliberately — this fires on every re-detection that
            // clears `scanInterval` (every ~1s while a code sits in frame), regardless
            // of whether the caller actually accepts it as a new scan. The caller knows
            // whether this is a genuinely new scan or the same code still lingering in
            // view, so it owns any user feedback such as vibration.
            return parentView.completion(.success(result))
        }

        func didFail(reason: QRScanError) {
            _ = parentView.completion(.failure(reason))
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

@available(iOS 17.0, *)
extension QRCodeScannerView.ScannerViewController: @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

        guard let metadataObject = metadataObjects.first,
              !parentView.isPaused,
              !didFinishScanning,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {

            return
        }

        // PATCH 1: screen-space bounds, via the preview layer this file now owns —
        // this is the transform upstream never applied.
        #if !targetEnvironment(simulator)
        let transformed = previewLayer?.transformedMetadataObject(for: readableObject)
        let screenRect = transformed?.bounds
        #else
        let screenRect: CGRect? = nil
        #endif

        let result = QRScanResult(
            string: stringValue,
            type: readableObject.type,
            corners: readableObject.corners,
            screenRect: screenRect
        )

        // PATCH 2: functional dispatch fires right here, synchronously — it no longer
        // waits on a photo capture. This mirrors upstream's scan-mode logic exactly,
        // just applied directly to `result` instead of inside a `handler` closure that
        // used to be deferred until the photo delegate ran.
        var wasAccepted = false
        switch parentView.scanMode {
        case .once:
            wasAccepted = found(result)
            didFinishScanning = true

        case .manual:
            if !didFinishScanning, isWithinManualCaptureInterval {
                wasAccepted = found(result)
                didFinishScanning = true
            }

        case .oncePerCode:
            if !codesFound.contains(stringValue) {
                codesFound.insert(stringValue)
                wasAccepted = found(result)
            }

        case .continuous:
            if isPastScanInterval {
                wasAccepted = found(result)
            }

        case .continuousExcept(let ignoredList):
            if isPastScanInterval, !ignoredList.contains(stringValue) {
                wasAccepted = found(result)
            }
        }

        // Cosmetic-only from here down: capture a photo to crop a thumbnail from.
        // `wasAccepted` is the caller's synchronous acknowledgement that this
        // exact metadata frame started a new scan cycle. Without that handshake, an
        // interval-throttled, duplicate, or already-processing detection could consume
        // `isThumbnailArmed`; its orphan image would then be discarded, leaving the
        // next real scan with no thumbnail. The remaining gates close synchronously
        // here (not through the slower SwiftUI state round-trip) and prevent overlap.
        #if !targetEnvironment(simulator)
        guard wasAccepted, parentView.requiresPhotoOutput, isThumbnailArmed, !isCapturing else { return }
        isThumbnailArmed = false
        startThumbnailCapture(
            payload: stringValue,
            screenRect: screenRect,
            previewBounds: previewLayer.bounds
        )
        #endif
    }
}

// MARK: - UIImagePickerControllerDelegate

@available(iOS 17.0, *)
extension QRCodeScannerView.ScannerViewController: UIImagePickerControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        isGalleryShowing = false

        defer {
            dismiss(animated: true)
        }

        guard let qrcodeImg = info[.originalImage] as? UIImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
              let ciImage = CIImage(image: qrcodeImg) else {

            return
        }

        let features = detector.features(in: ciImage)

        guard !features.isEmpty else {
            didFail(reason: .badOutput)
            return
        }
        for feature in features.compactMap({ $0 as? CIQRCodeFeature }) {
            guard let qrCodeLink = feature.messageString, !qrCodeLink.isEmpty else {
                didFail(reason: .badOutput)
                continue
            }

            let corners = [
                feature.bottomLeft,
                feature.bottomRight,
                feature.topRight,
                feature.topLeft
            ]

            let result = QRScanResult(string: qrCodeLink, type: .qr, corners: corners, screenRect: nil)
            found(result)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        isGalleryShowing = false
        dismiss(animated: true)
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

@available(iOS 17.0, *)
extension QRCodeScannerView.ScannerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isGalleryShowing = false
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

@available(iOS 17.0, *)
extension QRCodeScannerView.ScannerViewController: @preconcurrency AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            retryOrFinishThumbnailCapture(reason: error.localizedDescription)
            return
        }

        guard let context = pendingThumbnailContext else {
            retryOrFinishThumbnailCapture(reason: "Missing thumbnail capture context")
            return
        }

        guard let imageData = photo.fileDataRepresentation(),
              let qrImage = UIImage(data: imageData) else {
            retryOrFinishThumbnailCapture(reason: "Photo data could not be decoded")
            return
        }

        // `UIImage.cgImage` ignores `imageOrientation` — normalize first so the pixel
        // buffer we crop actually matches the visual (EXIF-corrected) orientation the
        // normalized bounds assume.
        let uprightImage = qrImage.normalizingOrientation()
        guard let cgImage = uprightImage.cgImage else {
            retryOrFinishThumbnailCapture(reason: "Photo has no CGImage backing")
            return
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let fullRect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let detectedRect = detectedQRCodeRect(in: cgImage, matching: context.payload)
        let fallbackRect = previewMappedRect(context: context, imageSize: fullRect.size)

        guard let sourceRect = detectedRect ?? fallbackRect else {
            retryOrFinishThumbnailCapture(reason: "QR could not be located in the still photo")
            return
        }

        let cropRect = paddedCropRect(sourceRect, within: fullRect)

        guard !cropRect.isEmpty, let croppedCGImage = cgImage.cropping(to: cropRect) else {
            retryOrFinishThumbnailCapture(reason: "Calculated crop rectangle is invalid")
            return
        }

        isCapturing = false
        pendingThumbnailContext = nil
        let thumbnail = UIImage(cgImage: croppedCGImage)
        DispatchQueue.main.async { [weak self] in
            self?.parentView.onThumbnailCaptured?(thumbnail)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }
}

private extension UIImage {
    /// Re-renders the image with `imageOrientation == .up`, so its `cgImage`'s raw
    /// pixel layout matches what's visually displayed (needed before cropping by pixel
    /// coordinates — `cgImage` alone ignores `imageOrientation`).
    func normalizingOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
