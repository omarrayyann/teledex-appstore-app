import ARKit
import CoreMotion
import simd

protocol ARKitManagerDelegate: AnyObject {
    func didUpdateRotationMatrix(_ rotationMatrix: simd_float3x3)
    func didUpdatePosition(_ position: SIMD3<Float>)
    func didSend(_ timeInterval: TimeInterval)
}

class ARKitManager: NSObject, ARSessionDelegate {
    var arSession = ARSession()
    var rotationMatrix: simd_float3x3 = matrix_identity_float3x3
    var position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var calibrationTransform: simd_float4x4 = matrix_identity_float4x4
    private let motionManager = CMMotionManager()
    @Published var isConnected: Bool = false
    @Published var toggle: Bool = false
    @Published var button: Bool = false
    @Published var webSocketManager = WebSocketManager()
    var ip = ""
    var port = ""
    var first = true
    weak var delegate: ARKitManagerDelegate?
    
    // Freeze state
    private var isFrozen = false
    private var frozenTransform: simd_float4x4?  // The calibrated transform when freeze started
    private var freezeOffset: simd_float4x4 = matrix_identity_float4x4  // Accumulated offset from all freezes
    
//    override init() {
//        super.init()
//        arSession.delegate = self
//        let configuration = ARWorldTrackingConfiguration()
//        configuration.planeDetection = [.horizontal, .vertical]
//
//        arSession.pause()
//        arSession.run(configuration)
//
//        
//    }
    
    override init() {
        super.init()
        arSession.delegate = self
        // Don't run the session here - wait until startSession() is called
    }
    
    func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
    

        if #available(iOS 15.0, *) {
            if let uwFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(
                where: { $0.captureDeviceType == .builtInUltraWideCamera }
            ) {
                configuration.videoFormat = uwFormat
                print("🛰️ Using ultra-wide camera format: \(uwFormat)")
            } else {
                print("⚠️ Ultra-wide camera not supported on this device; using default.")
            }
        }

        first = true  // Reset calibration flag
        arSession.run(configuration)
    }
    
    func connect(wsManager: WebSocketManager){
        self.webSocketManager = wsManager
    }
    
    func pauseSession() {
        arSession.pause()
        print("paused")
    }
    
    func disconnect(){
        pauseSession()
        self.webSocketManager.disconnect()
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !isFrozen else { return }
        
        if self.first {
            calibrate()
            first = false
        }
        var currentTransform = frame.camera.transform
        
        
        let m_rotationMatrix = simd_float4x4(
            SIMD4(0, -1, 0, 0),   // New X-axis (was -Z)
            SIMD4(0, 0, 1, 0),   // New Y-axis (was -X)
            SIMD4(-1, 0, 0, 0),   // New Z-axis (was Y)
            SIMD4(0, 0, 0, 1)    // No translation
        )

        // Apply the rotation to the current transform
        currentTransform = simd_mul(m_rotationMatrix, currentTransform)


        let calibratedTransform = simd_mul(currentTransform, calibrationTransform.inverse)
        
        // Apply freeze offset to get the adjusted transform
        // output = freezeOffset * calibratedTransform
        let adjustedTransform = simd_mul(freezeOffset, calibratedTransform)
        
        let rotationMatrix = simd_float3x3(
            SIMD3(adjustedTransform.columns.0.x, adjustedTransform.columns.0.y, adjustedTransform.columns.0.z),
            SIMD3(adjustedTransform.columns.1.x, adjustedTransform.columns.1.y, adjustedTransform.columns.1.z),
            SIMD3(adjustedTransform.columns.2.x, adjustedTransform.columns.2.y, adjustedTransform.columns.2.z)
        )
        let position = SIMD3<Float>(adjustedTransform.columns.3.x, adjustedTransform.columns.3.y, adjustedTransform.columns.3.z)
        
        DispatchQueue.main.async {
            self.rotationMatrix = rotationMatrix
            self.position = position
            
            self.delegate?.didUpdateRotationMatrix(rotationMatrix)
            self.delegate?.didUpdatePosition(position)
            
            var startTime = Date()
            self.webSocketManager.sendPose(rotationMatrix: rotationMatrix, position: position)
            var endTime = Date()
            var timeInterval = endTime.timeIntervalSince(startTime)
            self.delegate?.didSend(timeInterval)
            
        }
    }
    
    func calibrate() {
        if let currentTransformTemp = arSession.currentFrame {
            
            var currentTransform = currentTransformTemp.camera.transform
            let m_rotationMatrix = simd_float4x4(
                SIMD4(0, -1, 0, 0),   // New X-axis (was -Z)
                SIMD4(0, 0, 1, 0),   // New Y-axis (was -X)
                SIMD4(-1, 0, 0, 0),   // New Z-axis (was Y)
                SIMD4(0, 0, 0, 1)    // No translation
            )
            
            // Apply the rotation to the current transform
            currentTransform = simd_mul(m_rotationMatrix, currentTransform)
            
            calibrationTransform = currentTransform
            isFrozen = false
            frozenTransform = nil
            freezeOffset = matrix_identity_float4x4
        }
    }
    
    func updateButton(status: Bool) {
        button = status
        webSocketManager.button = button
    }
    
    func updateButtonSecondary(status: Bool) {
        webSocketManager.buttonSecondary = status
    }
    
    func toggleClicked(){
        toggle.toggle()
        webSocketManager.toggle = toggle
    }
    
    func freezeTransforms() {
        if let frame = arSession.currentFrame {
            var currentTransform = frame.camera.transform
            let m_rotationMatrix = simd_float4x4(
                SIMD4(0, -1, 0, 0),   // New X-axis (was -Z)
                SIMD4(0, 0, 1, 0),   // New Y-axis (was -X)
                SIMD4(-1, 0, 0, 0),   // New Z-axis (was Y)
                SIMD4(0, 0, 0, 1)    // No translation
            )

            // Apply the rotation to the current transform
            currentTransform = simd_mul(m_rotationMatrix, currentTransform)
            let calibratedTransform = simd_mul(currentTransform, calibrationTransform.inverse)
            
            // Store the current output: frozenTransform = freezeOffset * calibratedTransform
            frozenTransform = simd_mul(freezeOffset, calibratedTransform)
        }
        isFrozen = true
    }
    
    func unfreezeTransforms() {
        if let frozenTransform = frozenTransform, let frame = arSession.currentFrame {
            var currentTransform = frame.camera.transform
            let m_rotationMatrix = simd_float4x4(
                SIMD4(0, -1, 0, 0),   // New X-axis (was -Z)
                SIMD4(0, 0, 1, 0),   // New Y-axis (was -X)
                SIMD4(-1, 0, 0, 0),   // New Z-axis (was Y)
                SIMD4(0, 0, 0, 1)    // No translation
            )

            // Apply the rotation to the current transform
            currentTransform = simd_mul(m_rotationMatrix, currentTransform)
            let calibratedTransform = simd_mul(currentTransform, calibrationTransform.inverse)
            
            // We want: freezeOffset * calibratedTransform = frozenTransform
            // Therefore: freezeOffset = frozenTransform * inverse(calibratedTransform)
            freezeOffset = simd_mul(frozenTransform, calibratedTransform.inverse)
        }
        isFrozen = false
        self.frozenTransform = nil
    }
}
