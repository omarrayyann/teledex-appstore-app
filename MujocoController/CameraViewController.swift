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
    @IBOutlet weak var flipCameraButton: UIButton!
    
    // Use ARSession for both pose tracking and camera feed
    private var arSession = ARSession()
    private var handLandmarker: HandLandmarker?
    var webManager = WebSocketManager()
    private var isUsingBackCamera = true  // Track current camera

    // ARKit components for device pose tracking
    private var currentDeviceRotation: simd_float3x3 = matrix_identity_float3x3
    private var currentDevicePosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var calibrationTransform: simd_float4x4 = matrix_identity_float4x4
    private var isFirstFrame = true
    
    // MediaPipe optimization: separate queue and cached landmarks
    private let mediaPipeQueue = DispatchQueue(label: "com.mujoco.mediapipe", qos: .userInitiated)
    private var lastMediaPipeProcessTime: TimeInterval = 0
    private let mediaPipeInterval: TimeInterval = 1.0 / 20.0  // 20 FPS for MediaPipe
    
    // Thread-safe cached landmarks (updated by MediaPipe, read by pose sender)
    private let landmarksLock = NSLock()
    private var cachedLandmarks: [[Float]]? = nil
    private var cachedWorldLandmarks: [[Float]]? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Apply corner radius styling to match ViewController
        buttonLeave.layer.cornerRadius = buttonLeave.frame.height/2
        resetButton.layer.cornerRadius = resetButton.frame.height/2
        flipCameraButton.layer.cornerRadius = flipCameraButton.frame.height/2
        connectedStatusView.layer.cornerRadius = connectedStatusView.frame.height/2
        connectedIndicator.layer.cornerRadius = connectedIndicator.frame.height/2
        previewView.layer.cornerRadius = previewView.frame.height/40
        
        overlayView.backgroundColor = .clear
        webManager.delegate = self
        setupHandLandmarker()
        setupARSession()  // Only setup ARSession, not separate camera
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ensure overlayView matches previewView
        overlayView.frame = previewView.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        arSession.pause()  // Only pause ARSession
    }

    // MARK: - ARKit Setup (replaces separate camera setup)
    private func setupARSession() {
        arSession.delegate = self
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        
        // Always use back camera for AR (removed front camera option)
        arSession.run(configuration)
        
        // Create ARSCNView for preview (replaces AVCaptureVideoPreviewLayer)
        let arscnView = ARSCNView(frame: previewView.bounds)
        arscnView.session = arSession
        arscnView.automaticallyUpdatesLighting = false
        arscnView.rendersCameraGrain = false
        arscnView.rendersMotionBlur = false
        // Ensure the camera view fills the entire preview area
        arscnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.insertSubview(arscnView, at: 0)
        
        print("🎥 ARKit camera session started")
    }

    // MARK: - HandLandmarker Setup
    private func setupHandLandmarker() {
        guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            fatalError("hand_landmarker.task not found")
        }

        var options = HandLandmarkerOptions()
        options.runningMode = .liveStream
        options.numHands = 1
        options.minHandDetectionConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.baseOptions.modelAssetPath = modelPath
        options.handLandmarkerLiveStreamDelegate = self

        do {
            handLandmarker = try HandLandmarker(options: options)
        } catch {
            fatalError("Failed to create HandLandmarker: \(error)")
        }
    }

    // MARK: - ARSessionDelegate (handles both pose tracking AND hand detection)
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 1) Handle device pose tracking
        if isFirstFrame {
            calibrateARKit()
            isFirstFrame = false
        }
        
        var currentTransform = frame.camera.transform
        
        // Apply coordinate system rotation (same as ARKitManager)
        let m_rotationMatrix = simd_float4x4(
            SIMD4(0, -1, 0, 0),   // New X-axis (was -Z)
            SIMD4(0, 0, 1, 0),   // New Y-axis (was -X)
            SIMD4(-1, 0, 0, 0),   // New Z-axis (was Y)
            SIMD4(0, 0, 0, 1)    // No translation
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
        
        // Get cached landmarks (thread-safe read)
        landmarksLock.lock()
        let landmarks = cachedLandmarks
        let worldLandmarks = cachedWorldLandmarks
        landmarksLock.unlock()
        
        // Send device pose at full ARKit frame rate (60-120 FPS) with latest landmarks
        webManager.sendPose(
            rotationMatrix: rotationMatrix,
            position: position,
            fingerAngles: nil,
            landmarks: landmarks,  // Use cached landmarks (may be nil if no hand detected yet)
            worldLandmarksPositions: worldLandmarks
        )
        
        // 2) Throttle MediaPipe processing to avoid slowdown
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastMediaPipeProcessTime >= mediaPipeInterval else { return }
        lastMediaPipeProcessTime = currentTime
        
        // Process hand detection on separate queue (non-blocking)
        guard let handLandmarker = handLandmarker else { return }
        let pixelBuffer = frame.capturedImage
        
        mediaPipeQueue.async { [weak self] in
            guard let self = self else { return }
            // Convert to BGRA and detect hands
            if let bgraBuffer = convertToBGRA(from: pixelBuffer),
               let mpImage = try? MPImage(pixelBuffer: bgraBuffer, orientation: .up) {
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                try? handLandmarker.detectAsync(image: mpImage, timestampInMilliseconds: timestamp)
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

    // MARK: - MediaPipe Callback
    func handLandmarker(
        _ handLandmarker: HandLandmarker,
        didFinishDetection result: HandLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let res = result, let lm = res.landmarks.first, let wlm = res.worldLandmarks.first {
            // Extract landmark positions [[x, y, z]] from normalized landmarks
            let landmarkPositions: [[Float]] = lm.map { landmark in
                return [landmark.x, landmark.y, landmark.z]
            }
            
            // Extract world landmark positions [[x, y, z]]
            let worldLandmarksPositions: [[Float]] = wlm.map { landmark in
                return [landmark.x, landmark.y, landmark.z]
            }
            
            // Update cached landmarks (thread-safe write)
            landmarksLock.lock()
            cachedLandmarks = landmarkPositions
            cachedWorldLandmarks = worldLandmarksPositions
            landmarksLock.unlock()
            
            // Update UI overlay
            updateHandOverlay(landmarks: lm)
            
            print("🖐 Hand detected: cached \(landmarkPositions.count) landmarks + \(worldLandmarksPositions.count) world landmarks")
        } else {
            // No hand detected - clear cached landmarks
            landmarksLock.lock()
            cachedLandmarks = nil
            cachedWorldLandmarks = nil
            landmarksLock.unlock()
            
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
    
    @IBAction func flipCameraPressed(_ sender: Any) {
        isUsingBackCamera.toggle()
        
        // Reconfigure ARSession with new camera
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        
        // ARWorldTracking only supports back camera, so switch to ARFaceTracking for front
        if isUsingBackCamera {
            arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            print("📷 Switched to back camera")
        } else {
            // Use ARFaceTrackingConfiguration for front camera
            if ARFaceTrackingConfiguration.isSupported {
                let faceConfig = ARFaceTrackingConfiguration()
                arSession.run(faceConfig, options: [.resetTracking, .removeExistingAnchors])
                print("📷 Switched to front camera")
            } else {
                // If face tracking not supported, fall back to back camera
                isUsingBackCamera = true
                arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                print("⚠️ Front camera not supported, staying on back camera")
            }
        }
        
        // Recalibrate after camera switch
        isFirstFrame = true
    }
    
    // MARK: - WebSocketManagerDelegate
    func webSocketManager(_ manager: WebSocketManager, didConnect connected: Bool) {
        print("WebSocket connected: \(connected)")
    }
}

// MARK: - Helper Extensions

/// Converts any CVPixelBuffer to BGRA format using CoreImage.
func convertToBGRA(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()

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

    context.render(ciImage, to: outputBuffer)
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
