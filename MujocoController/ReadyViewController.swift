import UIKit

class ReadyViewController: UIViewController {
    
    @IBOutlet weak var goButton: UIButton!
    @IBOutlet weak var messageLabel: UILabel!
    
    var webSocketManager: WebSocketManager?
    var ipAddress: String?
    var port: String?
    var isHandMode: Bool = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor(red: 0.05, green: 0.1, blue: 0.16, alpha: 1.0)
        
        goButton.layer.cornerRadius = goButton.frame.height / 2
        goButton.backgroundColor = .white
        goButton.setTitleColor(.black, for: .normal)
    }
    
    @IBAction func goButtonPressed(_ sender: UIButton) {
        if isHandMode {
            performSegue(withIdentifier: "showCameraFromReady", sender: self)
        } else {
            performSegue(withIdentifier: "showARFromReady", sender: self)
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showARFromReady" {
            if let destinationVC = segue.destination as? ViewController {
                destinationVC.ipAddress = ipAddress
                destinationVC.port = port
                destinationVC.webSocketManager = webSocketManager!
                destinationVC.modalPresentationStyle = .fullScreen
            }
        } else if segue.identifier == "showCameraFromReady" {
            if let destinationVC = segue.destination as? CameraViewController {
                destinationVC.webManager = webSocketManager!
                destinationVC.modalPresentationStyle = .fullScreen
            }
        }
    }
}
