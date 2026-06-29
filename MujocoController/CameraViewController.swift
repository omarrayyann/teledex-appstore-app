// CameraViewController.swift

import UIKit
import AVFoundation
import MediaPipeTasksVision
import ARKit
import SceneKit
import simd

class CameraViewController: UIViewController,
                            HandLandmarkerLiveStreamDelegate,
                            WebSocketManagerDelegate,
                            ARSessionDelegate {

    @IBOutlet weak var buttonLeave: UIButton!
    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var overlayView: OverlayView!
    @IBOutlet weak var resetButton: UIButton!
    @IBOutlet weak var connectedStatusView: UIView!
    @IBOutlet weak var connectedIndicator: UIView!
    @IBOutlet weak var connectedLabel: UILabel!
    
    // ARSession for pose tracking (back camera) + optional face tracking (front camera)
    private var arSession = ARSession()
    private var arscnView: ARSCNView?
    
    private var handLandmarker: HandLandmarker?
    var webManager = WebSocketManager()

    // ARKit components for device pose tracking
    private var currentDeviceRotation: simd_float3x3 = matrix_identity_float3x3
    private var currentDevicePosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var calibrationTransform: simd_float4x4 = matrix_identity_float4x4
    private var isFirstFrame = true
    
    // MediaPipe optimization: cached landmarks
    private var lastMediaPipeProcessTime: TimeInterval = 0
    private let mediaPipeInterval: TimeInterval = 1.0 / 30.0  // 30 FPS for MediaPipe
    
    // Monotonically increasing timestamp for MediaPipe (must never go backwards)
    private var mediaPipeTimestamp: Int = 0
    
    // Reusable CIContext (creating one per frame is expensive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // Latest landmarks — written by MediaPipe callback, read by ARKit delegate for sending
    // Using a simple serial queue for thread safety instead of NSLock
    private var latestLandmarks: [[Float]]? = nil
    private var latestWorldLandmarks: [[Float]]? = nil
    private var landmarksVersion: UInt64 = 0        // Incremented on every update
    private var lastSentLandmarksVersion: UInt64 = 0 // Track what we last sent

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Apply corner radius styling to match ViewController
        buttonLeave.layer.cornerRadius = buttonLeave.frame.height/2
        resetButton.layer.cornerRadius = resetButton.frame.height/2
        connectedStatusView.layer.cornerRadius = connectedStatusView.frame.height/2
        connectedIndicator.layer.cornerRadius = connectedIndicator.frame.height/2
        previewView.layer.cornerRadius = previewView.frame.height/40
        
        overlayView.backgroundColor = .clear
        webManager.delegate = self
        setupHandLandmarker()
        setupARSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayView.frame = previewView.bounds
        arscnView?.frame = previewView.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        arSession.pause()
    }

    // MARK: - ARKit Setup
    // Uses ARFaceTrackingConfiguration with isWorldTrackingEnabled:
    // - Primary camera = FRONT → capturedImage is front camera (for MediaPipe hand detection + display)
    // - Back camera used internally → frame.camera.transform provides 6DOF world tracking pose
    private func setupARSession() {
        arSession.delegate = self
        
        // Use face tracking config so the primary (displayed) camera is the FRONT camera
        let configuration = ARFaceTrackingConfiguration()
        
        // Select highest resolution video format for better MediaPipe quality
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if let bestFormat = formats.max(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
            configuration.videoFormat = bestFormat
            print("📐 Using video format: \(bestFormat.imageResolution) @ \(bestFormat.framesPerSecond)fps")
        }
        
        // Enable world tracking so we still get 6DOF device pose from the back camera
        if ARFaceTrackingConfiguration.supportsWorldTracking {
            configuration.isWorldTrackingEnabled = true
            print("🌍 World tracking enabled on face-tracking config (6DOF pose via back camera)")
        } else {
            print("⚠️ World tracking not supported in face-tracking mode on this device")
        }
        
        arSession.run(configuration)
        
        // Display front camera feed via ARSCNView
        let scnView = ARSCNView(frame: previewView.bounds)
        scnView.session = arSession
        scnView.automaticallyUpdatesLighting = false
        scnView.rendersCameraGrain = false
        scnView.rendersMotionBlur = false
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.insertSubview(scnView, at: 0)
        self.arscnView = scnView
        
        print("🎥 ARKit session started (front camera displayed, back camera for pose tracking)")
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

    // MARK: - ARSessionDelegate (pose from back camera, MediaPipe on front camera)
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Handle device pose tracking
        if isFirstFrame {
            calibrateARKit()
            isFirstFrame = false
        }
        
        var currentTransform = frame.camera.transform
        
        // Apply coordinate system rotation (same as ARKitManager)
        let m_rotationMatrix = simd_float4x4(
            SIMD4(0, -1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-1, 0, 0, 0),
            SIMD4(0, 0, 0, 1)
        )
        
        currentTransform = simd_mul(m_rotationMatrix, currentTransform)
        let calibratedTransform = simd_mul(currentTransform, calibrationTransform.inverse)
        
        // Extract rotation matrix and position
        let rotationMatrix = simd_float3x3(
            SIMD3(calibratedTransform.columns.0.x, calibratedTransform.columns.0.y, calibratedTransform.columns.0.z),
            SIMD3(calibratedTransform.columns.1.x, calibratedTransform.columns.1.y, calibratedTransform.columns.1.z),
            SIMD3(calibratedTransform.columns.2.x, calibratedTransform.columns.2.y, calibratedTransform.columns.2.z)
        )
        let position = SIMD3<Float>(calibratedTransform.columns.3.x, calibratedTransform.columns.3.y, calibratedTransform.columns.3.z)
        
        // Update current device pose
        currentDeviceRotation = rotationMatrix
        currentDevicePosition = position
        
        // Send device pose with latest landmarks
        webManager.sendPose(
            rotationMatrix: rotationMatrix,
            position: position,
            fingerAngles: nil,
            landmarks: latestLandmarks,
            worldLandmarksPositions: latestWorldLandmarks
        )
        
        // Throttle MediaPipe processing on front camera frames (capturedImage = front camera)
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastMediaPipeProcessTime >= mediaPipeInterval else { return }
        lastMediaPipeProcessTime = currentTime
        
        guard let handLandmarker = handLandmarker else { return }
        
        let pixelBuffer = frame.capturedImage  // FRONT camera (ARFaceTrackingConfiguration)
        
        // Use monotonically increasing timestamp (MediaPipe drops frames if timestamps go backwards)
        mediaPipeTimestamp += 33  // ~30fps in milliseconds
        let timestamp = mediaPipeTimestamp
        
        // Convert and detect synchronously — pixel buffer is only valid during this callback.
        // detectAsync() returns immediately (enqueues work internally), so this won't block ARKit.
        let orientation = currentFrontCameraImageOrientation()
        if let bgraBuffer = convertToBGRA(from: pixelBuffer, context: self.ciContext),
           let mpImage = try? MPImage(pixelBuffer: bgraBuffer, orientation: orientation) {
            do {
                try handLandmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestamp)
            } catch {
                print("⚠️ MediaPipe detectAsync error: \(error)")
            }
        }
    }
    
    private func calibrateARKit() {
        if let currentFrame = arSession.currentFrame {
            var currentTransform = currentFrame.camera.transform
            
            // Apply the same coordinate system rotation
            let m_rotationMatrix = simd_float4x4(
                SIMD4(0, -1, 0, 0),
                SIMD4(0, 0, 1, 0),
                SIMD4(-1, 0, 0, 0),
                SIMD4(0, 0, 0, 1)
            )
            
            currentTransform = simd_mul(m_rotationMatrix, currentTransform)
            calibrationTransform = currentTransform
        }
    }

    private func currentFrontCameraImageOrientation() -> UIImage.Orientation {
        let orientation = UIDevice.current.orientation

        switch orientation {
        case .portrait:
            return .leftMirrored
        case .portraitUpsideDown:
            return .rightMirrored
        case .landscapeLeft:
            return .downMirrored
        case .landscapeRight:
            return .upMirrored
        default:
            return .leftMirrored
        }
    }

    /// Rotates the front camera pixel buffer from landscape sensor orientation to portrait,
    /// and converts to BGRA for MediaPipe. Uses CIImage affine transforms for correctness.
    private func rotatePixelBufferToPortrait(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Front camera in ARKit: sensor is landscape-left.
        // For portrait: rotate 90° CW and mirror horizontally
        // Transform: rotate -90° (CW) then mirror X
        let rotated = ciImage
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(width)))
            .transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: CGFloat(height), y: 0))
        
        // Output is portrait: width=height, height=width of original
        var outputBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         height, width,  // Swapped for portrait
                                         kCVPixelFormatType_32BGRA,
                                         attrs,
                                         &outputBuffer)
        
        guard status == kCVReturnSuccess, let output = outputBuffer else { return nil }
        
        let context = CIContext()
        context.render(rotated, to: output)
        return output
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
            // Extract landmark positions [[x, y, z]] from normalized landmarks
            let landmarkPositions: [[Float]] = lm.map { landmark in
                return [landmark.x, landmark.y, landmark.z]
            }
            
            // Extract world landmark positions [[x, y, z]]
            let worldLandmarksPositions: [[Float]] = wlm.map { landmark in
                return [landmark.x, landmark.y, landmark.z]
            }
            
            // Update latest landmarks directly (ARKit delegate runs on main thread,
            // and this callback also dispatches to main thread for safety)
            DispatchQueue.main.async {
                self.latestLandmarks = landmarkPositions
                self.latestWorldLandmarks = worldLandmarksPositions
                self.landmarksVersion += 1
                
                // Send immediately with current pose so landmarks are never stale
                self.webManager.sendPose(
                    rotationMatrix: self.currentDeviceRotation,
                    position: self.currentDevicePosition,
                    fingerAngles: nil,
                    landmarks: landmarkPositions,
                    worldLandmarksPositions: worldLandmarksPositions
                )
            }
            
            // Update UI overlay
            updateHandOverlay(landmarks: lm)
            
            print("🖐 Hand detected: \(landmarkPositions.count) landmarks (v\(landmarksVersion))")
        } else {
            DispatchQueue.main.async {
                self.latestLandmarks = nil
                self.latestWorldLandmarks = nil
                self.landmarksVersion += 1
            }
            
            // Clear overlay
            DispatchQueue.main.async {
                self.overlayView.draw(overlays: [])
            }
        }
    }
    
    // MARK: - Helper: Update Hand Overlay
    private func updateHandOverlay(landmarks lm: [NormalizedLandmark]) {

        DispatchQueue.main.async {
            // Use the actual overlay view dimensions directly
            let overlayW = self.overlayView.bounds.width
            let overlayH = self.overlayView.bounds.height

            let viewPts: [CGPoint] = lm.map { lm in
                let xNorm = CGFloat(lm.x)
                let yNorm = CGFloat(lm.y)

                // Simple direct mapping to overlay bounds with horizontal mirroring
                let px = (1.0 - yNorm) * overlayW  // Mirror horizontally
                let py = xNorm * overlayH

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
                let a = viewPts[idxPair.0]
                let b = viewPts[idxPair.1]
                return Line(from: a, to: b)
            }
            let overlay = HandOverlay(dots: viewPts, lines: lines)
            self.overlayView.draw(overlays: [overlay])
        }
    }

    // MARK: - UI Actions

        @IBAction func clickedLeave(_ sender: Any) {
        // Dismiss all the way back to root
        view.window?.rootViewController?.dismiss(animated: true, completion: nil)
    }
    
    @IBAction func resetPosePressed(_ sender: Any) {
        calibrateARKit()
        print("🔄 Pose reset - new calibration applied")
    }
    
    // MARK: - WebSocketManagerDelegate
    func webSocketManager(_ manager: WebSocketManager, didConnect connected: Bool) {
        print("WebSocket connected: \(connected)")
    }
}

// MARK: - Helper Extensions

/// Converts any CVPixelBuffer to BGRA format using CoreImage.
func convertToBGRA(from pixelBuffer: CVPixelBuffer, context: CIContext? = nil) -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let ctx = context ?? CIContext()

    var bgraBuffer: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                     width,
                                     height,
                                     kCVPixelFormatType_32BGRA,
                                     attrs,
                                     &bgraBuffer)

    guard status == kCVReturnSuccess, let outputBuffer = bgraBuffer else {
        return nil
    }

    ctx.render(ciImage, to: outputBuffer)
    return outputBuffer
}

// MARK: - HandAngles helper

struct HandAngles {
    /// Each finger's landmark indices in MediaPipe's 0–20 schema.
    static let jointIndices: [[Int]] = [
        [4, 3, 2, 1],      // thumb: TIP → DIP → PIP → MCP
        [8, 7, 6, 5, 0],   // index: TIP → DIP → PIP → MCP → wrist
        [12,11,10,9, 0],   // middle
        [16,15,14,13, 0],  // ring
        [20,19,18,17, 0],  // little
    ]
    
    static func angles(from landmarks: [NormalizedLandmark]) -> [Float] {
        return jointIndices.map { indices in
            var total: Float = 0
            for i in 0..<indices.count - 2 {
                let A = landmarks[indices[i]]
                let B = landmarks[indices[i + 1]]
                let C = landmarks[indices[i + 2]]
                total += angle(at: B, from: A, to: C)
            }
            return total
        }
    }

    private static func angle(
        at b: NormalizedLandmark,
        from a: NormalizedLandmark,
        to c: NormalizedLandmark
    ) -> Float {
        let v1 = simd_float3(a.x - b.x, a.y - b.y, a.z - b.z)
        let v2 = simd_float3(c.x - b.x, c.y - b.y, c.z - b.z)
        let dot = simd_dot(v1, v2)
        let mag = simd_length(v1) * simd_length(v2)
        let cosθ = max(-1, min(1, dot / mag))
        return acos(cosθ)
    }
}
