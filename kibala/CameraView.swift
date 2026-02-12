import SwiftUI

struct CameraView: View {
    @StateObject var cameraService = CameraService()
    @ObservedObject var c2paManager = C2PAManager.shared

    @State private var showError = false
    @State private var errorMessage = ""
    @State private var signedFileURL: URL?
    @State private var showShareSheet = false
    @State private var isPublished = false

    var body: some View {
        ZStack {
            if let image = cameraService.capturedImage {

                // ── Photo preview + action buttons ──
                if let fileURL = signedFileURL {
                    // After signing succeeded: show share/done UI
                    signedPhotoView(image: image, fileURL: fileURL)
                } else {
                    // Before signing: show retake/sign buttons
                    unsignedPhotoView(image: image)
                }

            } else {
                // ── Camera live preview ──
                cameraLiveView
            }
        }
        .onAppear {
            cameraService.checkPermissions()
        }
        .alert("C2PA Signing Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = signedFileURL {
                ShareSheet(fileURL: url)
            }
        }
    }

    // MARK: - Subviews

    /// Shows the captured photo with Retake / Sign buttons.
    private func unsignedPhotoView(image: UIImage) -> some View {
        VStack {
            Spacer()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding()
                .shadow(radius: 10)

            Spacer()

            HStack(spacing: 40) {
                Button(action: {
                    cameraService.capturedImage = nil
                    signedFileURL = nil
                }) {
                    Text("Retake")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(10)
                }
                .disabled(c2paManager.isProcessing)

                Button(action: {
                    Task {
                        do {
                            let url = try await c2paManager.signImage(image: image)
                            signedFileURL = url
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                            print("❌ Error during Secure Save: \(error)")
                        }
                    }
                }) {
                    if c2paManager.isProcessing {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            Text("Signing...")
                                .foregroundColor(.black)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .cornerRadius(10)
                    } else {
                        Text("Save Secure (C2PA)")
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                }
                .disabled(c2paManager.isProcessing)
            }
            .padding(.bottom, 50)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }

    /// Shows the signed photo with Share / New Photo buttons.
    /// Share exports the RAW signed JPEG file (with C2PA metadata intact).
    private func signedPhotoView(image: UIImage, fileURL: URL) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding()
                .shadow(radius: 10)
                .overlay(
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label(
                                isPublished ? "Published via Gateway" : "C2PA Signed",
                                systemImage: isPublished ? "globe.badge.chevron.backward" : "checkmark.seal.fill"
                            )
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(isPublished ? Color.blue.opacity(0.85) : Color.green.opacity(0.85))
                                .cornerRadius(8)
                                .padding(12)
                        }
                    }
                )

            Spacer()

            Text(isPublished
                 ? "Published photo re-signed by the Privacy Gateway."
                 : "Signed photo saved to app Documents.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(isPublished
                 ? "The gateway's certificate replaces your device identity."
                 : "Use **Share** to export, or **Publish** to re-sign via the gateway.")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button(action: {
                    showShareSheet = true
                }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                }

                if !isPublished {
                    Button(action: {
                        guard let url = signedFileURL else { return }
                        Task {
                            do {
                                let publishedURL = try await c2paManager.uploadAndPublish(fileURL: url)
                                signedFileURL = publishedURL
                                isPublished = true
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                                print("❌ Publish error: \(error)")
                            }
                        }
                    }) {
                        if c2paManager.isProcessing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                Text("Publishing...")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.purple.opacity(0.7))
                            .cornerRadius(10)
                        } else {
                            Label("Publish", systemImage: "arrow.up.forward.app")
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.purple)
                                .cornerRadius(10)
                        }
                    }
                    .disabled(c2paManager.isProcessing)
                }

                Button(action: {
                    signedFileURL = nil
                    cameraService.capturedImage = nil
                    isPublished = false
                }) {
                    Text("New Photo")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.6))
                        .cornerRadius(10)
                }
            }
            .padding(.bottom, 50)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }

    /// Camera live preview with shutter and Reset Keys buttons.
    private var cameraLiveView: some View {
        ZStack {
            CameraPreview(cameraService: cameraService)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()

                    Button(action: {
                        C2PAManager.shared.resetCredentials()
                    }) {
                        VStack {
                            Image(systemName: "gearshape.fill")
                                .font(.title)
                                .foregroundColor(.white)
                            Text("Reset Keys")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(10)
                    }
                    .padding(.top, 50)
                    .padding(.trailing, 20)
                }

                Spacer()

                Button(action: {
                    cameraService.capturePhoto()
                }) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 80, height: 80)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 65, height: 65)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}
