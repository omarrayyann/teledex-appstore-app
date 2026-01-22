// WebSocketManager.swift

import Foundation
import Combine
import simd
import UIKit

protocol WebSocketManagerDelegate: AnyObject {
    /// Called when the connection status changes.
    func webSocketManager(_ manager: WebSocketManager, didConnect connected: Bool)
}

class WebSocketManager: ObservableObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?  // Keep strong reference to prevent deallocation
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published state
    @Published var toggle: Bool = false
    @Published var button: Bool = false
    @Published var buttonSecondary: Bool = false
    @Published var isConnected: Bool = false
    @Published var receivedImage: UIImage?

    var ipAddress: String?
    var port: String?

    weak var delegate: WebSocketManagerDelegate?

    // MARK: - Connection
    func connect(ip: String, port: String) {
        self.ipAddress = ip
        self.port = port
        guard let url = URL(string: "ws://\(ip):\(port)") else {
            print("WebSocketManager: invalid URL ws://\(ip):\(port)")
            return
        }
        print("WebSocketManager: connecting to \(url)")
        urlSession = URLSession(configuration: .default)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        // Don't set isConnected = true here - wait for actual response
        // Start listening which will confirm connection
        listen()
    }
    
    func connect(ip: String, port: String, completion: @escaping (Bool) -> Void) {
        self.ipAddress = ip
        self.port = port
        guard let url = URL(string: "ws://\(ip):\(port)") else {
            print("WebSocketManager: invalid URL ws://\(ip):\(port)")
            completion(false)
            return
        }
        print("WebSocketManager: connecting to \(url)")
        
        // Create session - keep strong reference
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        var hasCompleted = false
        let completionLock = NSLock()
        
        // Timeout after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            completionLock.lock()
            if !hasCompleted {
                hasCompleted = true
                completionLock.unlock()
                print("WebSocketManager: connection timed out")
                self?.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self?.isConnected = false
                completion(false)
            } else {
                completionLock.unlock()
            }
        }
        
        // Send a ping to verify connection
        webSocketTask?.sendPing { [weak self] error in
            completionLock.lock()
            if hasCompleted {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            
            DispatchQueue.main.async {
                if let error = error {
                    print("WebSocketManager: ping failed - \(error.localizedDescription)")
                    self?.isConnected = false
                    self?.delegate?.webSocketManager(self!, didConnect: false)
                    completion(false)
                } else {
                    print("WebSocketManager: ping succeeded - connected!")
                    self?.isConnected = true
                    self?.delegate?.webSocketManager(self!, didConnect: true)
                    self?.listen()
                    self?.startPingTimer()
                    completion(true)
                }
            }
        }
    }

    func disconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: "Client disconnect".data(using: .utf8))
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        isSending = false
        delegate?.webSocketManager(self, didConnect: false)
        print("WebSocketManager: disconnected")
    }

    // MARK: - Sending
    private var isSending = false
    
    func send(json: [String: Any]) {
        guard isConnected, let ws = webSocketTask else {
            return
        }
        
        // Skip if previous send still in progress to avoid queue buildup
        guard !isSending else { return }
        isSending = true
        
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            guard let text = String(data: data, encoding: .utf8) else { 
                isSending = false
                return 
            }
            let message = URLSessionWebSocketTask.Message.string(text)
            ws.send(message) { [weak self] error in
                self?.isSending = false
                // Ignore send errors - don't disconnect, just keep trying
                if let error = error {
                    print("WebSocketManager send error:", error)
                }
            }
        } catch {
            isSending = false
            print("WebSocketManager serialization error:", error)
        }
    }

    // MARK: - Public API
    func sendPose(
        rotationMatrix: simd_float3x3,
        position: SIMD3<Float>,
        fingerAngles: [Float]? = nil,   // Made optional since we're focusing on landmarks
        landmarks: [[Float]]? = nil,
        worldLandmarksPositions: [[Float]]? = nil
    ) {
        let rotationArray = [
            [rotationMatrix.columns.0.x, rotationMatrix.columns.0.y, rotationMatrix.columns.0.z],
            [rotationMatrix.columns.1.x, rotationMatrix.columns.1.y, rotationMatrix.columns.1.z],
            [rotationMatrix.columns.2.x, rotationMatrix.columns.2.y, rotationMatrix.columns.2.z]
        ]
        let positionArray = [position.x, position.y, position.z]

        var payload: [String: Any] = [
            "rotation": rotationArray,
            "position": positionArray,
            "toggle": toggle,
            "button": button,
            "button_secondary": buttonSecondary
        ]

        // Only include finger angles if provided
        if let angles = fingerAngles {
            payload["finger_angles"] = angles
        }

        // Include landmarks data (primary focus)
        if let lmArray = landmarks {
            payload["landmarks"] = lmArray
            print("WebSocketManager: sending \(lmArray.count) landmarks")
        } else {
            print("WebSocketManager: no landmarks provided")
        }
        
        if let wlmArray = worldLandmarksPositions {
            payload["world_landmarks"] = wlmArray
            print("WebSocketManager: sending \(wlmArray.count) world landmarks")
        }

        send(json: payload)
    }

    // MARK: - Receiving
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("WebSocketManager received text:", text)
                case .data(let data):
                    print("WebSocketManager received data of length:", data.count)
                    if let img = UIImage(data: data) {
                        DispatchQueue.main.async { self.receivedImage = img }
                    }
                @unknown default:
                    print("WebSocketManager received unknown message")
                }
                self.listen()
            case .failure(let error):
                print("WebSocketManager receive error:", error)
                // Don't set isConnected = false here - receive errors can be transient
                // Only disconnect on actual send failures or explicit disconnect
                // Try to continue listening
                if self.isConnected {
                    self.listen()
                }
            }
        }
    }
    
    // Keep connection alive with periodic pings
    private var pingTimer: Timer?
    
    func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error = error {
                    print("WebSocketManager: ping failed - \(error)")
                }
            }
        }
    }
    
    func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}
