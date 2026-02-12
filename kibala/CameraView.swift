import SwiftUI

// MARK: - CameraView

struct CameraView: View {
    @StateObject var cameraService = CameraService()
    @ObservedObject var c2paManager = C2PAManager.shared

    @State private var showError = false
    @State private var errorMessage = ""
    @State private var signedFileURL: URL?
    @State private var showShareSheet = false
    @State private var isPublished = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Full-black canvas behind everything
            Color.black.ignoresSafeArea()

            if let image = cameraService.capturedImage {
                if let fileURL = signedFileURL {
                    signedPhotoView(image: image, fileURL: fileURL)
                } else {
                    unsignedPhotoView(image: image)
                }
            } else {
                cameraLiveView
            }
        }
        .onAppear { cameraService.checkPermissions() }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = signedFileURL { ShareSheet(fileURL: url) }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    // MARK: - Camera Live View

    private var cameraLiveView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 16:9 cinematic preview
            GeometryReader { geo in
                let width = geo.size.width
                let height = width * 16 / 9
                CameraPreview(cameraService: cameraService)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(width: geo.size.width, height: geo.size.height)
            }

            Spacer(minLength: 0)

            // ── Liquid Glass Tab Bar ──
            glassTabBar
                .padding(.bottom, 12)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Liquid Glass Tab Bar

    private var glassTabBar: some View {
        HStack(spacing: 0) {
            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
            }

            Spacer()

            // Shutter
            Button { cameraService.capturePhoto() } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 72, height: 72)
                    Circle()
                        .stroke(.white.opacity(0.6), lineWidth: 3)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(.white)
                        .frame(width: 56, height: 56)
                }
            }

            Spacer()

            // Placeholder for symmetry
            Color.clear
                .frame(width: 52, height: 52)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationView {
            List {
                Section {
                    Button(role: .destructive) {
                        C2PAManager.shared.resetCredentials()
                        showSettings = false
                    } label: {
                        Label("Reset Credentials", systemImage: "trash")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Deletes the Secure Enclave key and cached certificate. A new key pair will be generated on the next signing.")
                }

                Section("About") {
                    LabeledContent("App", value: "Kibala")
                    LabeledContent("Signing", value: "C2PA / ES256")
                    LabeledContent("Key Storage", value: "Secure Enclave")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Unsigned Photo (Retake / Sign)

    private func unsignedPhotoView(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(
                    width: UIScreen.main.bounds.width,
                    height: UIScreen.main.bounds.width * 16 / 9
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer(minLength: 0)

            // Action pills
            HStack(spacing: 14) {
                glassPill(label: "Retake", icon: "arrow.counterclockwise", tint: .red.opacity(0.75)) {
                    cameraService.capturedImage = nil
                    signedFileURL = nil
                }
                .disabled(c2paManager.isProcessing)

                if c2paManager.isProcessing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                        Text("Signing…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
                } else {
                    glassPill(label: "Sign & Share", icon: "checkmark.seal.fill", tint: .green.opacity(0.65)) {
                        Task {
                            do {
                                let url = try await c2paManager.signImage(image: image)
                                signedFileURL = url
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Signed Photo (Share / Publish / New)

    private func signedPhotoView(image: UIImage, fileURL: URL) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: UIScreen.main.bounds.width,
                        height: UIScreen.main.bounds.width * 16 / 9
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Status badge
                HStack(spacing: 5) {
                    Image(systemName: isPublished ? "globe.badge.chevron.backward" : "checkmark.seal.fill")
                    Text(isPublished ? "Published" : "Signed")
                        .fontWeight(.semibold)
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isPublished ? Color.blue.opacity(0.8) : Color.green.opacity(0.8))
                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
                )
                .padding(14)
            }

            Spacer(minLength: 0)

            // Info text
            VStack(spacing: 4) {
                Text(isPublished
                     ? "Published — photographer identity removed."
                     : "Signed with C2PA. Ready to share or publish.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))

                if !isPublished {
                    Text("**Publish** sends to the gateway for anonymous re-signing.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 12)

            // Action pills
            HStack(spacing: 12) {
                glassPill(label: "Share", icon: "square.and.arrow.up", tint: .blue.opacity(0.6)) {
                    showShareSheet = true
                }

                if !isPublished {
                    if c2paManager.isProcessing {
                        HStack(spacing: 6) {
                            ProgressView().tint(.white)
                            Text("Publishing…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
                    } else {
                        glassPill(label: "Publish", icon: "arrow.up.forward.app", tint: .purple.opacity(0.6)) {
                            Task {
                                do {
                                    let url = try await c2paManager.uploadAndPublish(fileURL: fileURL)
                                    signedFileURL = url
                                    isPublished = true
                                } catch {
                                    errorMessage = error.localizedDescription
                                    showError = true
                                }
                            }
                        }
                    }
                }

                glassPill(label: "New", icon: "camera.fill", tint: .white.opacity(0.15)) {
                    signedFileURL = nil
                    cameraService.capturedImage = nil
                    isPublished = false
                }
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Reusable Glass Pill Button

    private func glassPill(
        label: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(tint))
                        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
    }
}
