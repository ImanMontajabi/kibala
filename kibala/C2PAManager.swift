import Foundation
import UIKit
@preconcurrency import C2PA
import Combine
import Security

// MARK: - Models

struct EnrollmentResponse: Codable {
    let certificate_chain: String
    let certificate_id: String
    let expires_at: String
    let serial_number: String
}

struct EnrollmentRequest: Codable {
    let csr: String
    let metadata: [String: String]
}

// MARK: - Errors

enum C2PASigningError: LocalizedError {
    case jpegConversionFailed
    case invalidCertificateChain
    case invalidServerURL
    case networkError(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .jpegConversionFailed:
            return "Failed to convert image to JPEG"
        case .invalidCertificateChain:
            return "Invalid or empty certificate chain received from server"
        case .invalidServerURL:
            return "Invalid server URL"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .signingFailed(let msg):
            return "C2PA signing failed: \(msg)"
        }
    }
}

// MARK: - C2PAManager

class C2PAManager: ObservableObject {
    static let shared = C2PAManager()

    private let SERVER_URL = "http://192.168.178.46:8080"
    private let KEY_TAG = "com.imanmontajabi.kibala.secure.key"

    @Published var isProcessing = false
    @Published var lastError: String?

    // MARK: - Public API

    /// Signs a UIImage with C2PA credentials and returns the file URL of the signed JPEG.
    ///
    /// The signed file is saved to the app's Documents directory so the raw bytes
    /// (including the C2PA JUMBF manifest) are preserved exactly. This is critical
    /// because the Photos framework re-encodes images and strips C2PA metadata.
    func signImage(image: UIImage) async throws -> URL {
        await MainActor.run {
            isProcessing = true
            lastError = nil
        }

        do {
            guard let imageData = image.jpegData(compressionQuality: 1.0) else {
                throw C2PASigningError.jpegConversionFailed
            }
            print("📸 JPEG data ready: \(imageData.count) bytes")

            let signer = try await createSecureEnclaveSigner()
            print("✅ Signer created successfully")

            // Run the heavy Rust-based signing on a raw POSIX thread.
            //
            // Why Thread.detachNewThread instead of Task.detached or DispatchQueue?
            // - Task.detached: Swift's cooperative pool can still schedule it on the
            //   main thread (we saw _dispatch_main_queue_drain in the backtrace).
            // - DispatchQueue.global: GCD boosts the worker via priority inheritance
            //   when a User-interactive thread awaits the continuation
            //   (_dispatch_queue_override_invoke).
            // - Thread.detachNewThread: Creates a raw pthread completely outside GCD's
            //   QoS system. No priority tracking → no priority inversion detection.
            //   The Rust C2PA runtime's internal Default-QoS threads are invisible
            //   to the Thread Performance Checker from this context.
            let fileURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                Thread.detachNewThread {
                    do {
                        let result = try self.performSigning(imageData: imageData, signer: signer)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            await MainActor.run { isProcessing = false }
            print("✅ Signed photo saved to: \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Gateway Upload

    /// Uploads a locally signed JPEG to the privacy gateway for re-signing.
    ///
    /// The gateway verifies the device's C2PA manifest, adds it as an
    /// ingredient (parentOf), and re-signs with the gateway's own certificate.
    /// Returns the URL of the re-signed JPEG saved to Documents.
    func uploadAndPublish(fileURL: URL) async throws -> URL {
        await MainActor.run {
            isProcessing = true
            lastError = nil
        }

        do {
            guard let url = URL(string: "\(SERVER_URL)/api/v1/publish") else {
                throw C2PASigningError.invalidServerURL
            }

            let fileData = try Data(contentsOf: fileURL)

            // Build multipart/form-data request
            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body

            print("🌐 Uploading to gateway: \(fileData.count) bytes")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw C2PASigningError.networkError("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw C2PASigningError.networkError("Gateway \(httpResponse.statusCode): \(errorMsg)")
            }

            // Save the re-signed JPEG to Documents
            let fm = FileManager.default
            let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let kibalaDir = docsDir.appendingPathComponent("KibalaPhotos", isDirectory: true)
            try fm.createDirectory(at: kibalaDir, withIntermediateDirectories: true)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let destURL = kibalaDir.appendingPathComponent("Kibala_Published_\(timestamp).jpg")

            try data.write(to: destURL)

            print("✅ Published photo saved: \(destURL.lastPathComponent) (\(data.count) bytes)")

            await MainActor.run { isProcessing = false }
            return destURL
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Signing

    /// Synchronous signing logic — called from a detached Task, never from MainActor.
    /// Returns the URL of the signed JPEG in the app's Documents directory.
    private func performSigning(imageData: Data, signer: Signer) throws -> URL {
        let fm = FileManager.default
        let uuid = UUID().uuidString

        // Temp files for builder I/O
        let tempDir = fm.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("c2pa_input_\(uuid).jpg")
        let outputURL = tempDir.appendingPathComponent("c2pa_output_\(uuid).jpg")

        defer {
            try? fm.removeItem(at: inputURL)
            // outputURL is cleaned up after copying to Documents
        }

        try imageData.write(to: inputURL)
        print("📁 Temp input: \(inputURL.lastPathComponent)")

        let manifestJSON = buildManifestJSON()
        let builder = try Builder(manifestJSON: manifestJSON)

        let sourceStream = try Stream(readFrom: inputURL)
        let destStream = try Stream(writeTo: outputURL)

        print("🔏 Signing photo on background thread...")
        try builder.sign(
            format: "image/jpeg",
            source: sourceStream,
            destination: destStream,
            signer: signer
        )

        // Copy the signed file to Documents so it persists and has raw C2PA bytes.
        // The Photos library re-encodes images and strips JUMBF/C2PA metadata,
        // so we MUST keep the original file for verification to work.
        let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let kibalaDir = docsDir.appendingPathComponent("KibalaPhotos", isDirectory: true)
        try fm.createDirectory(at: kibalaDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let destFileURL = kibalaDir.appendingPathComponent("Kibala_\(timestamp)_\(uuid.prefix(8)).jpg")

        try fm.moveItem(at: outputURL, to: destFileURL)

        let fileSize = (try? fm.attributesOfItem(atPath: destFileURL.path)[.size] as? Int) ?? 0
        print("✅ C2PA signing complete — \(fileSize) bytes → \(destFileURL.lastPathComponent)")
        return destFileURL
    }

    // MARK: - Manifest

    private func buildManifestJSON() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // "format" is intentionally omitted — it is passed to builder.sign() instead.
        return """
        {
            "claim_generator": "Kibala App/1.0",
            "title": "Kibala Secure Photo",
            "assertions": [
                {
                    "label": "c2pa.actions",
                    "data": {
                        "actions": [
                            {
                                "action": "c2pa.created",
                                "softwareAgent": "Kibala App/1.0",
                                "when": "\(timestamp)"
                            }
                        ]
                    }
                },
                {
                    "label": "stds.schema-org.CreativeWork",
                    "data": {
                        "@context": "http://schema.org",
                        "@type": "CreativeWork",
                        "author": [
                            {
                                "@type": "Person",
                                "name": "Iman Montajabi"
                            }
                        ]
                    }
                }
            ]
        }
        """
    }

    // MARK: - Signer Creation

    private func createSecureEnclaveSigner() async throws -> Signer {
        let certChainKey = KEY_TAG + ".certchain"

        // 1. Try to use a previously cached certificate chain
        if let cachedCert = loadCertFromKeychain(account: certChainKey) {
            print("🔑 Using cached certificate chain")
            let normalized = normalizePEMChain(cachedCert)
            let config = SecureEnclaveSignerConfig(keyTag: KEY_TAG, accessControl: [.privateKeyUsage])
            return try Signer(
                algorithm: .es256,
                certificateChainPEM: normalized,
                tsaURL: nil,
                secureEnclaveConfig: config
            )
        }

        // 2. No cached cert — run the enrollment flow
        print("🆕 No cached certificate. Starting enrollment...")

        // Ensure a Secure Enclave key exists (only creates if missing)
        try ensureSecureEnclaveKeyExists()

        let certConfig = CertificateManager.CertificateConfig(
            commonName: "Kibala Secure Camera",
            organization: "Kibala",
            organizationalUnit: "iOS Team",
            country: "DE",
            state: "Lower Saxony",
            locality: "Osnabrueck",
            emailAddress: "iman@example.com"
        )

        let csrPEM = try CertificateManager.createCSR(keyTag: KEY_TAG, config: certConfig)
        print("📝 CSR generated")

        // 3. Send CSR to the Python signing server
        let certChain = try await fetchCertFromServer(csr: csrPEM)
        let normalized = normalizePEMChain(certChain)

        // Validate the chain has at least one certificate
        let certCount = normalized.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        print("📜 Certificate chain contains \(certCount) certificate(s)")
        guard certCount >= 1 else {
            throw C2PASigningError.invalidCertificateChain
        }

        // 4. Cache the chain for future sessions
        saveCertToKeychain(cert: normalized, account: certChainKey)
        print("💾 Certificate chain cached to Keychain")

        let config = SecureEnclaveSignerConfig(keyTag: KEY_TAG, accessControl: [.privateKeyUsage])
        return try Signer(
            algorithm: .es256,
            certificateChainPEM: normalized,
            tsaURL: nil,
            secureEnclaveConfig: config
        )
    }

    // MARK: - Secure Enclave Key Management

    /// Checks for an existing Secure Enclave key with our tag.
    /// Only creates a new key if none exists, preventing duplicate keys
    /// that could cause public-key / certificate mismatches.
    private func ensureSecureEnclaveKeyExists() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: KEY_TAG,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess {
            print("🔑 Secure Enclave key already exists")
            return
        }

        print("🔑 Creating new Secure Enclave key...")
        let config = SecureEnclaveSignerConfig(keyTag: KEY_TAG, accessControl: [.privateKeyUsage])
        _ = try Signer.createSecureEnclaveKey(config: config)
        print("✅ Secure Enclave key created")
    }

    // MARK: - Certificate Chain Helpers

    /// Normalizes a PEM certificate chain: extracts each BEGIN/END block,
    /// trims whitespace, and joins them with a single newline.
    /// This prevents formatting-related C2PA failures from extra whitespace
    /// or missing newlines between certificates.
    private func normalizePEMChain(_ chain: String) -> String {
        let blocks = chain.components(separatedBy: "-----END CERTIFICATE-----")
        var certs: [String] = []

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("-----BEGIN CERTIFICATE-----") {
                certs.append(trimmed + "\n-----END CERTIFICATE-----")
            }
        }

        guard !certs.isEmpty else {
            return chain.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return certs.joined(separator: "\n")
    }

    // MARK: - Network

    private func fetchCertFromServer(csr: String) async throws -> String {
        guard let url = URL(string: "\(SERVER_URL)/api/v1/certificates/sign") else {
            throw C2PASigningError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = EnrollmentRequest(csr: csr, metadata: ["device": "iPhone"])
        request.httpBody = try JSONEncoder().encode(body)

        print("🌐 Sending CSR to server...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw C2PASigningError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw C2PASigningError.networkError("Server \(httpResponse.statusCode): \(errorMsg)")
        }

        let result = try JSONDecoder().decode(EnrollmentResponse.self, from: data)
        print("✅ Certificate received from server (id: \(result.certificate_id))")
        return result.certificate_chain
    }

    // MARK: - Keychain

    private func saveCertToKeychain(cert: String, account: String) {
        guard let data = cert.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain save failed: \(status)")
        }
    }

    private func loadCertFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Reset

    func resetCredentials() {
        let certChainKey = KEY_TAG + ".certchain"

        // Delete cached certificate chain
        let queryCert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: certChainKey
        ]
        SecItemDelete(queryCert as CFDictionary)

        // Delete Secure Enclave key using the SDK's own method,
        // which correctly matches the tag format used during creation.
        _ = Signer.deleteSecureEnclaveKey(keyTag: KEY_TAG)

        print("🗑️ All keys and certificates have been cleared.")
    }
}

