import UIKit
import NVActivityIndicatorView
import AVFoundation

class StartViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    @IBOutlet weak var addressTextField: UITextField!
    @IBOutlet weak var connectButton: UIButton!
    @IBOutlet weak var handPoseButton: UIButton!
    @IBOutlet weak var addressBack: UIView!

    @IBOutlet weak var loading: NVActivityIndicatorView!
    
    // QR Scanner views from storyboard
    @IBOutlet weak var qrContainerView: UIView!
    @IBOutlet weak var scannerLabel: UILabel!
    
    var webSocketManager: WebSocketManager?
    var isHandMode: Bool = false
    var currentIPAddress: String = ""
    var currentPort: String = ""
    
    // QR Scanner
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var qrCodeDetected = false

    override func viewDidLoad() {
        super.viewDidLoad()
        
        connectButton.layer.cornerRadius = connectButton.frame.height / 2
        handPoseButton.layer.cornerRadius = handPoseButton.frame.height / 2
        
        // Style input background - only bottom corners rounded
        addressBack.layer.cornerRadius = 16
        addressBack.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        addressBack.layer.borderWidth = 1
        addressBack.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
        addressBack.clipsToBounds = true
        addressBack.backgroundColor = .white
        
        loading.stopAnimating()
        
        // Restore cached IP:Port
        let cachedIP = getString(forKey: "ip")
        let cachedPort = getString(forKey: "port")
        if !cachedIP.isEmpty && !cachedPort.isEmpty {
            addressTextField.text = "\(cachedIP):\(cachedPort)"
        }
        
        // Setup QR scanner camera
        setupQRScanner()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startQRScanner()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopQRScanner()
    }
    
    func setupQRScanner() {
        // Style the container - only top corners rounded
        qrContainerView.layer.cornerRadius = 16
        qrContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        qrContainerView.clipsToBounds = true
        qrContainerView.backgroundColor = .black
        
        // Style the label
        scannerLabel.textColor = .white
        scannerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        scannerLabel.layer.cornerRadius = 8
        scannerLabel.clipsToBounds = true
        
        // Add corner brackets for visual guide
        addScannerCorners()
    }
    
    func addScannerCorners() {
        let cornerLength: CGFloat = 30
        let cornerWidth: CGFloat = 3
        let inset: CGFloat = 20
        
        // We'll add these after layout
        qrContainerView.layoutIfNeeded()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let bounds = self.qrContainerView.bounds
            let cornerViews = [
                // Top-left
                self.createCornerView(x: inset, y: inset, horizontal: true, vertical: true, length: cornerLength, width: cornerWidth),
                // Top-right
                self.createCornerView(x: bounds.width - inset - cornerLength, y: inset, horizontal: true, vertical: false, length: cornerLength, width: cornerWidth),
                // Bottom-left
                self.createCornerView(x: inset, y: bounds.height - inset - cornerLength, horizontal: false, vertical: true, length: cornerLength, width: cornerWidth),
                // Bottom-right
                self.createCornerView(x: bounds.width - inset - cornerLength, y: bounds.height - inset - cornerLength, horizontal: false, vertical: false, length: cornerLength, width: cornerWidth)
            ]
            
            for cornerView in cornerViews {
                self.qrContainerView.addSubview(cornerView)
            }
            
            // Bring label to front
            self.qrContainerView.bringSubviewToFront(self.scannerLabel)
        }
    }
    
    func createCornerView(x: CGFloat, y: CGFloat, horizontal: Bool, vertical: Bool, length: CGFloat, width: CGFloat) -> UIView {
        let container = UIView(frame: CGRect(x: x, y: y, width: length, height: length))
        container.backgroundColor = .clear
        
        // Horizontal line
        let hLine = UIView()
        hLine.backgroundColor = .white
        if horizontal && vertical { // top-left
            hLine.frame = CGRect(x: 0, y: 0, width: length, height: width)
        } else if horizontal && !vertical { // top-right
            hLine.frame = CGRect(x: 0, y: 0, width: length, height: width)
        } else if !horizontal && vertical { // bottom-left
            hLine.frame = CGRect(x: 0, y: length - width, width: length, height: width)
        } else { // bottom-right
            hLine.frame = CGRect(x: 0, y: length - width, width: length, height: width)
        }
        container.addSubview(hLine)
        
        // Vertical line
        let vLine = UIView()
        vLine.backgroundColor = .white
        if horizontal && vertical { // top-left
            vLine.frame = CGRect(x: 0, y: 0, width: width, height: length)
        } else if horizontal && !vertical { // top-right
            vLine.frame = CGRect(x: length - width, y: 0, width: width, height: length)
        } else if !horizontal && vertical { // bottom-left
            vLine.frame = CGRect(x: 0, y: 0, width: width, height: length)
        } else { // bottom-right
            vLine.frame = CGRect(x: length - width, y: 0, width: width, height: length)
        }
        container.addSubview(vLine)
        
        return container
    }
    
    func startQRScanner() {
        // Reset QR detection flag so we can scan again
        qrCodeDetected = false
        
        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCaptureSession()
                    } else {
                        self?.showCameraPlaceholder()
                    }
                }
            }
        case .denied, .restricted:
            showCameraPlaceholder()
        @unknown default:
            break
        }
    }
    
    func showCameraPlaceholder() {
        scannerLabel.text = "Tap to enable camera"
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(requestCameraAccess))
        qrContainerView.addGestureRecognizer(tapGesture)
    }
    
    @objc func requestCameraAccess() {
        let alert = UIAlertController(title: "Camera Access Needed", message: "Please enable camera access in Settings to scan QR codes.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    
    func setupCaptureSession() {
        // If session exists, clean it up first
        if captureSession != nil {
            captureSession?.stopRunning()
            previewLayer?.removeFromSuperlayer()
            captureSession = nil
            previewLayer = nil
        }
        
        captureSession = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            return
        }
        
        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            return
        }
        
        if captureSession!.canAddInput(videoInput) {
            captureSession!.addInput(videoInput)
        } else {
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if captureSession!.canAddOutput(metadataOutput) {
            captureSession!.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            return
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
        previewLayer!.videoGravity = .resizeAspectFill
        previewLayer!.frame = qrContainerView.bounds
        qrContainerView.layer.insertSublayer(previewLayer!, at: 0)
        
        // Update frame when layout changes
        DispatchQueue.main.async { [weak self] in
            self?.previewLayer?.frame = self?.qrContainerView.bounds ?? .zero
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }
    
    func stopQRScanner() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        // Clean up session so it gets recreated fresh next time
        previewLayer?.removeFromSuperlayer()
        captureSession = nil
        previewLayer = nil
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = qrContainerView.bounds
    }
    
    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !qrCodeDetected else { return }
        
        if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           metadataObject.type == .qr,
           let stringValue = metadataObject.stringValue {
            
            // Parse IP:Port format
            if let (ip, port) = parseQRCode(stringValue) {
                qrCodeDetected = true
                
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                
                // Fill in the combined field
                addressTextField.text = "\(ip):\(port)"
                
                // Save values
                saveString(ip, forKey: "ip")
                saveString(port, forKey: "port")
                
                // Visual feedback - flash green
                UIView.animate(withDuration: 0.2, animations: {
                    self.qrContainerView.layer.borderWidth = 4
                    self.qrContainerView.layer.borderColor = UIColor.systemGreen.cgColor
                    self.scannerLabel.text = "✓ \(ip):\(port)"
                    self.scannerLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
                }) { _ in
                    // Reset after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        UIView.animate(withDuration: 0.3) {
                            self?.qrContainerView.layer.borderWidth = 0
                            self?.scannerLabel.text = "Scan QR Code"
                            self?.scannerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
                        }
                        self?.qrCodeDetected = false
                    }
                }
            }
        }
    }
    
    func parseQRCode(_ code: String) -> (ip: String, port: String)? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        
        // Handle format: "ip:port"
        if let colonRange = trimmed.range(of: ":", options: .backwards) {
            let ip = String(trimmed[..<colonRange.lowerBound])
            let port = String(trimmed[colonRange.upperBound...])
            
            if !ip.isEmpty && !port.isEmpty && Int(port) != nil {
                return (ip, port)
            }
        }
        return nil
    }
    
    func parseAddress(_ address: String) -> (ip: String, port: String)? {
        let components = address.split(separator: ":")
        guard components.count == 2 else { return nil }
        let ip = String(components[0]).trimmingCharacters(in: .whitespaces)
        let port = String(components[1]).trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !port.isEmpty else { return nil }
        return (ip, port)
    }
    
    @IBAction func howToUse(_ sender: Any) {
        if let url = URL(string: "https://github.com/omarrayyann/teledex") {
            UIApplication.shared.open(url)
        }
    }
    
    func saveString(_ string: String, forKey key: String) {
        UserDefaults.standard.set(string, forKey: key)
    }

    func getString(forKey key: String) -> String {
        return UserDefaults.standard.string(forKey: key) ?? ""
    }
    
    @IBAction func proceedButtonPressed(_ sender: UIButton) {
        guard let address = addressTextField.text, !address.isEmpty else {
            let alert = UIAlertController(title: "Missing Info", message: "Please enter IP:Port address.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        guard let (ipAddress, port) = parseAddress(address) else {
            let alert = UIAlertController(title: "Invalid Format", message: "Please enter address as IP:Port\n(e.g. 192.168.1.100:8080)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        saveString(ipAddress, forKey: "ip")
        saveString(port, forKey: "port")
        
        // Show loading indicator and disable UI
        loading.startAnimating()
        setUIEnabled(false)
        
        checkWebSocketConnection(ipAddress: ipAddress, port: port) { [weak self] success in
            DispatchQueue.main.async {
                // Hide loading indicator and enable UI
                self?.loading.stopAnimating()
                self?.setUIEnabled(true)
                
                if success {
                    self?.isHandMode = false
                    self?.currentIPAddress = ipAddress
                    self?.currentPort = port
                    self?.performSegue(withIdentifier: "showReady", sender: self)
                } else {
                    // Show an alert if the connection failed
                    let alert = UIAlertController(title: "Connection Failed", message: "Could not connect to \(ipAddress):\(port)\n\nMake sure:\n• Server is running\n• Same Wi-Fi network\n• Correct IP and port", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                }
            }
        }
    }
    
    @IBAction func proceedHandButtonPressed(_ sender: UIButton) {
        guard let address = addressTextField.text, !address.isEmpty else {
            let alert = UIAlertController(title: "Missing Info", message: "Please enter IP:Port address.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        guard let (ipAddress, port) = parseAddress(address) else {
            let alert = UIAlertController(title: "Invalid Format", message: "Please enter address as IP:Port\n(e.g. 192.168.1.100:8080)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        saveString(ipAddress, forKey: "ip")
        saveString(port, forKey: "port")
        
        // Show loading indicator and disable UI
        loading.startAnimating()
        setUIEnabled(false)
        
        checkWebSocketConnection(ipAddress: ipAddress, port: port) { [weak self] success in
            DispatchQueue.main.async {
                // Hide loading indicator and enable UI
                self?.loading.stopAnimating()
                self?.setUIEnabled(true)
                
                if success {
                    self?.isHandMode = true
                    self?.currentIPAddress = ipAddress
                    self?.currentPort = port
                    self?.performSegue(withIdentifier: "showReadyHand", sender: self)
                } else {
                    // Show an alert if the connection failed
                    let alert = UIAlertController(title: "Connection Failed", message: "Could not connect to \(ipAddress):\(port)\n\nMake sure:\n• Server is running\n• Same Wi-Fi network\n• Correct IP and port", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                }
            }
        }
    }
    
    func setUIEnabled(_ enabled: Bool) {
        addressTextField.isEnabled = enabled
        connectButton.isEnabled = enabled
    }
    
    func checkWebSocketConnection(ipAddress: String, port: String, completion: @escaping (Bool) -> Void) {
        self.webSocketManager = WebSocketManager()
        
        // Use the new completion-based connect that actually verifies connection
        self.webSocketManager!.connect(ip: ipAddress, port: port) { success in
            completion(success)
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showReady" || segue.identifier == "showReadyHand" {
            if let destinationVC = segue.destination as? ReadyViewController {
                destinationVC.webSocketManager = self.webSocketManager
                destinationVC.ipAddress = self.currentIPAddress
                destinationVC.port = self.currentPort
                destinationVC.isHandMode = self.isHandMode
                destinationVC.modalPresentationStyle = .fullScreen
            }
        }
    }
}
