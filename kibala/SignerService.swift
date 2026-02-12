import Foundation
import CryptoKit
import Security


class SignerService {
    private let tag = "com.imanmontajabi.c2pa.keys.myidentity".data(using: .utf8)!
    private var privateKey: SecureEnclave.P256.Signing.PrivateKey?
    
    init() {
        do {
            try loadCreateKey()
        } catch {
            print("FATAL ERROR: Could not load keys: \(error)")
        }
    }
    
    private func loadCreateKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnData as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess {
            print("No existing key found. Creating a new Key in Secure Enclave...")
            let keyData = item as! Data
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData)
            print("Key found successfully")
        } else {
            print("The old key format was used, generating a new one ...")
            do {
                try createNewKey()
            } catch {
                print("FATAL ERROR: Could not create new key: \(error)")
            }
        }
    }
    
    private func createNewKey() throws {
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        )!
        
        privateKey = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrAccessControl as String: accessControl,
            kSecValueRef as String: privateKey!.dataRepresentation
            
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
        print("The new key was created and saved.")
    }
    
    func sign(data: Data) -> Data? {
        guard let key = privateKey else { return nil }
        
        do {
            let signature = try key.signature(for: data)
            return signature.derRepresentation
        } catch {
            print("Signature operation failed: \(error)")
            return nil
        }
    }
    
    func getPublicKeyPEM() -> String {
        guard let key = privateKey else { return "Key not found" }
        
        let publicKey = key.publicKey
        let keyData = publicKey.x963Representation
        let keyBase64 = keyData.base64EncodedString()
        
        return "-----BEGIN PUBLIC KEY-----\n\(keyBase64)\n-----END PUBLIC KEY-----"
    }
}
