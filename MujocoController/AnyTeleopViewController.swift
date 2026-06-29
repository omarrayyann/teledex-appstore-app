// AnyTeleopViewController.swift
// Similar to CameraViewController but uses back camera and derives pose from MediaPipe wrist landmark

import UIKit
import AVFoundation
import MediaPipeTasksVision
import simd

class AnyTeleopViewController: UIViewController,
                                HandLandmarkerLiveStreamDelegate,
                                WebSocketManagerDelegate,
                                AVCaptureVideoDataOutputSampleBufferDelegate,
                                AVCaptureDepthDataOutputDelegate {

    @IBOutlet weak var buttonLeave: UIButton!
    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var overlayView: OverlayView!
    @IBOutlet weak var resetButton: UIButton!
    @IBOutlet weak var flipCameraButton: UIButton!
    @IBOutlet weak var connectedStatusView: UIView!
    @IBOutlet weak var connectedIndicator: UIView!
    @IBOutlet weak var connectedLabel: UILabel!

    // AVCaptureSession
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var usingFrontCamera = true  // front camera by default

    private var handLandmarker: HandLandmarker?
    var webManager = WebSocketManager()

    // MediaPipe throttling
    private var lastMediaPipeProcessTime: TimeInterval = 0
    private let mediaPipeInterval: TimeInterval = 1.0 / 30.0  // 30 FPS for MediaPipe

    // Monotonically increasing timestamp for MediaPipe
    private var mediaPipeTimestamp: Int = 0

    // Reusable CIContext
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Wrist-derived pose (from normalized landmarks + depth camera)
    private var currentWristPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var calibrationWristPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var hasCalibrated = false

    // Depth data from device depth camera (LiDAR / TrueDepth)
    private var latestDepthData: AVDepthData?
    private var depthOutput: AVCaptureDepthDataOutput?
    private let depthQueue = DispatchQueue(label: "com.anyteleop.depthQueue", qos: .userInitiated)

    // Fallback depth estimation when no depth sensor
    private var referenceHandSpan: Float = 0.0

    // One-Euro filter for each axis (smooth when still, responsive when moving)
    private var filterX = OneEuroFilter(minCutoff: 0.8, beta: 0.5, dCutoff: 1.0)
    private var filterY = OneEuroFilter(minCutoff: 0.8, beta: 0.5, dCutoff: 1.0)
    private var filterZ = OneEuroFilter(minCutoff: 0.5, beta: 0.3, dCutoff: 1.0)
    private var lastRawPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)  // for reset
    private var frameCount: Int = 0

    // Latest landmarks
    private var latestLandmarks: [[Float]]? = nil
    private var latestWorldLandmarks: [[Float]]? = nil

    // Keep a reference to the video output so we can update orientation
    private var videoOutput: AVCaptureVideoDataOutput?

    override func viewDidLoad() {
        super.viewDidLoad()

        buttonLeave.layer.cornerRadius = 12
        resetButton.layer.cornerRadius = 12
        flipCameraButton.layer.cornerRadius = 12
        connectedStatusView.layer.cornerRadius = 8
        connectedIndicator.layer.cornerRadius = connectedIndicator.frame.height / 2

        overlayView.backgroundColor = .clear
        webManager.delegate = self
        setupHandLandmarker()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayView.frame = previewView.bounds
        previewLayer?.frame = previewView.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.updateVideoOrientation()
            self.previewLayer?.frame = self.previewView.bounds
        })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        captureSession?.stopRunning()
    }

    // Support all orientations (iPad landscape)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    // MARK: - Camera Setup (AVCaptureSession with Depth)
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo  // .photo supports depth; .high does not

        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back

        // Find a depth-capable camera (LiDAR on back, TrueDepth on front)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTrueDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        
        // Prefer depth-capable devices first
        guard let camera = discoverySession.devices.first,
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("⚠️ Could not access \(usingFrontCamera ? "front" : "back") camera")
            return
        }
        
        let hasDepth = camera.deviceType == .builtInTrueDepthCamera ||
                       camera.deviceType == .builtInDualWideCamera ||
                       camera.deviceType == .builtInDualCamera

        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Video output for MediaPipe processing
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.anyteleop.videoQueue", qos: .userInitiated))
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = currentVideoOrientation()
                if usingFrontCamera && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
        }
        self.videoOutput = videoOutput

        // Depth output (if camera supports it)
        if hasDepth {
            let depthOut = AVCaptureDepthDataOutput()
            depthOut.setDelegate(self, callbackQueue: depthQueue)
            depthOut.isFilteringEnabled = true  // smooth depth
            depthOut.alwaysDiscardsLateDepthData = true
            
            if session.canAddOutput(depthOut) {
                session.addOutput(depthOut)
                
                // Select the best depth format
                if let depthConnection = depthOut.connection(with: .depthData) {
                    depthConnection.isEnabled = true
                }
                
                self.depthOutput = depthOut
                print("📏 Depth output enabled (\(camera.deviceType.rawValue))")
            }
        } else {
            self.depthOutput = nil
            self.latestDepthData = nil
            print("⚠️ No depth camera available — will use normalized z from MediaPipe")
        }

        // Remove old preview layer
        previewLayer?.removeFromSuperlayer()

        // Preview layer
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        if let previewConnection = layer.connection {
            previewConnection.videoOrientation = currentVideoOrientation()
        }
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        captureSession = session

        // Reset MediaPipe hand landmarker
        setupHandLandmarker()
        mediaPipeTimestamp = 0

        // Start capture
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }

        let cameraName = usingFrontCamera ? "Front" : "Back"
        let depthLabel = hasDepth ? " + Depth" : ""
        connectedLabel.text = "AnyTeleop — \(cameraName)\(depthLabel)"

        print("🎥 \(cameraName) camera started\(depthLabel) for AnyTeleop mode")
    }

    // MARK: - HandLandmarker Setup
    private func setupHandLandmarker() {
        guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            fatalError("hand_landmarker.task not found")
        }

        var options = HandLandmarkerOptions()
        options.runningMode = .liveStream
        options.numHands = 1
        options.minHandDetectionConfidence = 0.3
        options.minTrackingConfidence = 0.4
        options.baseOptions.modelAssetPath = modelPath
        options.handLandmarkerLiveStreamDelegate = self

        do {
            handLandmarker = try HandLandmarker(options: options)
        } catch {
            fatalError("Failed to create HandLandmarker: \(error)")
        }
    }

    // MARK: - Orientation Helpers

    /// Returns the AVCaptureVideoOrientation matching the current interface orientation.
    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        if let windowScene = view.window?.windowScene {
            switch windowScene.interfaceOrientation {
            case .portrait:            return .portrait
            case .portraitUpsideDown:   return .portraitUpsideDown
            case .landscapeLeft:       return .landscapeLeft
            case .landscapeRight:      return .landscapeRight
            default:                   return .portrait
            }
        }
        // Fallback before window is available
        return .landscapeRight
    }

    /// Updates both the preview layer and the video output connection orientation.
    private func updateVideoOrientation() {
        let orientation = currentVideoOrientation()
        if let previewConnection = previewLayer?.connection, previewConnection.isVideoOrientationSupported {
            previewConnection.videoOrientation = orientation
        }
        if let outputConnection = videoOutput?.connection(with: .video), outputConnection.isVideoOrientationSupported {
            outputConnection.videoOrientation = orientation
        }
    }

    // MARK: - AVCaptureDepthDataOutputDelegate
    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {
        // Convert to disparity float32 for easy sampling
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        self.latestDepthData = converted
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Throttle MediaPipe
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastMediaPipeProcessTime >= mediaPipeInterval else { return }
        lastMediaPipeProcessTime = currentTime

        guard let handLandmarker = handLandmarker else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Monotonically increasing timestamp
        mediaPipeTimestamp += 33
        let timestamp = mediaPipeTimestamp

        // Back camera in portrait orientation — already oriented via connection.videoOrientation
        if let mpImage = try? MPImage(pixelBuffer: pixelBuffer, orientation: .up) {
            do {
                try handLandmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestamp)
            } catch {
                print("⚠️ MediaPipe detectAsync error: \(error)")
            }
        }
    }

    // MARK: - MediaPipe Callback
    func handLandmarker(
        _ handLandmarker: HandLandmarker,
        didFinishDetection result: HandLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let error = error {
            print("⚠️ MediaPipe callback error: \(error)")
        }

        if let res = result, let lm = res.landmarks.first, let wlm = res.worldLandmarks.first {
            // Extract landmark positions
            let landmarkPositions: [[Float]] = lm.map { [$0.x, $0.y, $0.z] }
            let worldLandmarksPositions: [[Float]] = wlm.map { [$0.x, $0.y, $0.z] }

            // --- Compute wrist 3D position ---
            let wristNorm = lm[0]
            let wristX = Float(wristNorm.x)  // 0..1 in image
            let wristY = Float(wristNorm.y)  // 0..1 in image

            var wristDepth: Float = 0.0
            var hasRealDepth = false

            // Try to sample depth from the device depth camera (median of patch)
            if let depthData = self.latestDepthData {
                let depthMap = depthData.depthDataMap
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

                let depthW = CVPixelBufferGetWidth(depthMap)
                let depthH = CVPixelBufferGetHeight(depthMap)

                // Map normalized wrist coords to depth map pixel
                let cx = Int(wristX * Float(depthW))
                let cy = Int(wristY * Float(depthH))

                if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                    // Sample a 7x7 patch and take the median for robustness
                    let patchRadius = 3
                    var samples: [Float] = []
                    samples.reserveCapacity((patchRadius * 2 + 1) * (patchRadius * 2 + 1))
                    for dy in -patchRadius...patchRadius {
                        for dx in -patchRadius...patchRadius {
                            let sx = max(0, min(cx + dx, depthW - 1))
                            let sy = max(0, min(cy + dy, depthH - 1))
                            let rowPtr = baseAddress.advanced(by: sy * bytesPerRow)
                                .assumingMemoryBound(to: Float32.self)
                            let d = rowPtr[sx]
                            if d.isFinite && d > 0.05 && d < 5.0 {
                                samples.append(d)
                            }
                        }
                    }
                    if samples.count > 0 {
                        samples.sort()
                        wristDepth = samples[samples.count / 2]  // median
                        hasRealDepth = true
                    }
                }
            }

            // Build 3D position:
            // x, y: normalized coords centered at image center (no depth scaling needed)
            // z: depth in meters from sensor, or estimated from hand span
            let rawX = (wristX - 0.5)        // -0.5 to +0.5, right = positive
            let rawY = -(wristY - 0.5)       // -0.5 to +0.5, up = positive
            var rawZ: Float = 0.0

            if hasRealDepth {
                rawZ = wristDepth
            } else {
                // Fallback: estimate depth from apparent hand size
                let mcpNorm = lm[9]
                let ddx = Float(wristNorm.x - mcpNorm.x)
                let ddy = Float(wristNorm.y - mcpNorm.y)
                let handSpan = sqrtf(ddx * ddx + ddy * ddy)

                if !self.hasCalibrated {
                    self.referenceHandSpan = handSpan
                }
                rawZ = self.referenceHandSpan > 0 ? (self.referenceHandSpan / max(handSpan, 0.001) - 1.0) : 0.0
            }
            let rawWristPos = SIMD3<Float>(rawX, rawY, rawZ)

            DispatchQueue.main.async {
                self.latestLandmarks = landmarkPositions
                self.latestWorldLandmarks = worldLandmarksPositions
                self.frameCount += 1
                let t = Double(self.frameCount) / 30.0  // approximate timestamp

                // Auto-calibrate on first detection
                if !self.hasCalibrated {
                    self.calibrationWristPosition = rawWristPos
                    self.filterX.reset()
                    self.filterY.reset()
                    self.filterZ.reset()
                    self.hasCalibrated = true
                    print("🎯 AnyTeleop: calibrated wrist=\(rawWristPos), depth=\(hasRealDepth ? "sensor" : "estimated")")
                }

                // Store raw for reset
                self.lastRawPosition = rawWristPos

                // Position relative to calibration
                let rawCalibrated = rawWristPos - self.calibrationWristPosition

                // Apply One-Euro filter for smooth, responsive tracking
                let filteredX = self.filterX.filter(value: Double(rawCalibrated.x), timestamp: t)
                let filteredY = self.filterY.filter(value: Double(rawCalibrated.y), timestamp: t)
                let filteredZ = self.filterZ.filter(value: Double(rawCalibrated.z), timestamp: t)
                let calibratedPos = SIMD3<Float>(Float(filteredX), Float(filteredY), Float(filteredZ))
                self.currentWristPosition = calibratedPos

                // Send pose: identity rotation + wrist-derived position
                let identityRotation = matrix_identity_float3x3
                self.webManager.sendPose(
                    rotationMatrix: identityRotation,
                    position: calibratedPos,
                    fingerAngles: nil,
                    landmarks: landmarkPositions,
                    worldLandmarksPositions: worldLandmarksPositions
                )
            }

            // Update UI overlay
            updateHandOverlay(landmarks: lm)
        } else {
            DispatchQueue.main.async {
                self.latestLandmarks = nil
                self.latestWorldLandmarks = nil
            }

            DispatchQueue.main.async {
                self.overlayView.draw(overlays: [])
            }
        }
    }

    // MARK: - Helper: Update Hand Overlay
    private func updateHandOverlay(landmarks lm: [NormalizedLandmark]) {
        let isFront = self.usingFrontCamera
        DispatchQueue.main.async {
            let overlayW = self.overlayView.bounds.width
            let overlayH = self.overlayView.bounds.height

            let viewPts: [CGPoint] = lm.map { landmark in
                // Front camera is mirrored via connection, so direct mapping works for both
                let px = CGFloat(landmark.x) * overlayW
                let py = CGFloat(landmark.y) * overlayH
                return CGPoint(x: px, y: py)
            }

            let connections = [
                (0,1),(1,2),(2,3),(3,4),
                (0,5),(5,6),(6,7),(7,8),
                (0,9),(9,10),(10,11),(11,12),
                (0,13),(13,14),(14,15),(15,16),
                (0,17),(17,18),(18,19),(19,20)
            ]
            let lines = connections.map { idxPair in
                Line(from: viewPts[idxPair.0], to: viewPts[idxPair.1])
            }
            let overlay = HandOverlay(dots: viewPts, lines: lines)
            self.overlayView.draw(overlays: [overlay])
        }
    }

    // MARK: - UI Actions
    @IBAction func clickedLeave(_ sender: Any) {
        captureSession?.stopRunning()
        view.window?.rootViewController?.dismiss(animated: true, completion: nil)
    }

    @IBAction func resetPosePressed(_ sender: Any) {
        // Use current raw position as the new origin so position becomes (0,0,0)
        calibrationWristPosition = lastRawPosition
        filterX.reset()
        filterY.reset()
        filterZ.reset()
        currentWristPosition = SIMD3<Float>(0, 0, 0)
        referenceHandSpan = 0.0
        hasCalibrated = false
        print("🔄 AnyTeleop: pose reset to (0,0,0)")
    }

    @IBAction func flipCameraPressed(_ sender: Any) {
        // Stop current session
        captureSession?.stopRunning()
        // Toggle camera
        usingFrontCamera.toggle()
        // Reset calibration for new camera perspective
        hasCalibrated = false
        // Rebuild session with new camera
        setupCamera()
        print("🔄 AnyTeleop: switched to \(usingFrontCamera ? "front" : "back") camera")
    }

    // MARK: - WebSocketManagerDelegate
    func webSocketManager(_ manager: WebSocketManager, didConnect connected: Bool) {
        print("WebSocket connected: \(connected)")
    }
}

// MARK: - One-Euro Filter
// Adaptive low-pass filter: smooth when still, responsive when moving fast.
// Based on: https://cristal.univ-lille.fr/~casiez/1euro/
class OneEuroFilter {
    private var minCutoff: Double
    private var beta: Double
    private var dCutoff: Double
    private var xFilter: LowPassFilter
    private var dxFilter: LowPassFilter
    private var lastTime: Double?
    private var initialized = false

    init(minCutoff: Double = 1.0, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.xFilter = LowPassFilter(alpha: 1.0)
        self.dxFilter = LowPassFilter(alpha: 1.0)
    }

    func reset() {
        initialized = false
        lastTime = nil
        xFilter = LowPassFilter(alpha: 1.0)
        dxFilter = LowPassFilter(alpha: 1.0)
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(value: Double, timestamp: Double) -> Double {
        var dt: Double
        if let last = lastTime {
            dt = timestamp - last
            if dt <= 0 { dt = 1.0 / 30.0 }
        } else {
            dt = 1.0 / 30.0
        }
        lastTime = timestamp

        if !initialized {
            initialized = true
            xFilter = LowPassFilter(alpha: 1.0, initValue: value)
            dxFilter = LowPassFilter(alpha: alpha(cutoff: dCutoff, dt: dt), initValue: 0.0)
            return value
        }

        // Estimate derivative
        let prevX = xFilter.lastValue
        let dx = (value - prevX) / dt

        // Filter derivative
        let edx = dxFilter.filter(value: dx, alpha: alpha(cutoff: dCutoff, dt: dt))

        // Adaptive cutoff based on speed
        let cutoff = minCutoff + beta * abs(edx)

        // Filter signal
        return xFilter.filter(value: value, alpha: alpha(cutoff: cutoff, dt: dt))
    }
}

private class LowPassFilter {
    var lastValue: Double = 0.0
    private var initialized: Bool

    init(alpha: Double, initValue: Double = 0.0) {
        self.lastValue = initValue
        self.initialized = true
    }

    func filter(value: Double, alpha: Double) -> Double {
        let result = alpha * value + (1.0 - alpha) * lastValue
        lastValue = result
        return result
    }
}
