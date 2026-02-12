import UIKit
import AVFoundation
import Combine
import Photos


class CameraService: NSObject, ObservableObject {
    private var isCameraSetup = false
    var session: AVCaptureSession?
    var output = AVCapturePhotoOutput()
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage?
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    DispatchQueue.main.async {
                        self.setupCamera()
                    }
                }
            }
        case .authorized:
            setupCamera()
        default:
            print("Permission denied")
        }
    }
    
    func setupCamera() {
        if isCameraSetup { return }
        let session = AVCaptureSession()
        
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            
            DispatchQueue.main.async {
                self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
                self.previewLayer?.videoGravity = .resizeAspectFill
                self.previewLayer?.connection?.videoRotationAngle = 90
            }
            
            self.session = session
            self.isCameraSetup = true
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
    
    func saveImageToGallery() {
        guard let image = capturedImage else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, error in
            if success {
                print("Image successfully saved!")
                DispatchQueue.main.async {
                    self.capturedImage = nil
                }
            } else if let error = error {
                print("Saving Image Error: \(error.localizedDescription)")
            }
        }
    }
    
    func saveSignedPhotoToGallery(data: Data) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        } completionHandler: { success, error in
            if success {
                print("Signed C2PA photo saved to Gallery!")
                DispatchQueue.main.async {
                    self.capturedImage = nil
                }
            } else if let error = error {
                print("Error saving to gallery: \(error.localizedDescription)")
            }
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { print(error.localizedDescription); return }
        
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        
        DispatchQueue.main.async {
            self.capturedImage = image
        }
    }

}
