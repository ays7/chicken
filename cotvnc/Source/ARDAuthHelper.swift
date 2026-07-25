import Foundation
import CommonCrypto
import CryptoKit

@objc public class ARDAuthResult: NSObject {
    @objc public let clientPublicKey: Data
    @objc public let encryptedCredentials: Data

    public init(clientPublicKey: Data, encryptedCredentials: Data) {
        self.clientPublicKey = clientPublicKey
        self.encryptedCredentials = encryptedCredentials
        super.init()
    }
}

// MARK: - RoyalVNCKit 1:1 BigNum Implementation
fileprivate final class BigNum {
    private var bigInt: CS.BigUInt

    init() {
        self.bigInt = .init()
    }

    init?(data: Data) {
        self.bigInt = .init(data)
    }

    var isZero: Bool {
        self.bigInt == 0
    }

    var bytesCount: Int32 {
        .init(self.bigInt.serialize().count)
    }

    var bitsCount: Int32 {
        .init(self.bigInt.bitWidth)
    }

    func rand(range: BigNum) -> Bool {
        self.bigInt = CS.BigUInt.randomInteger(lessThan: range.bigInt)
        return true
    }

    static func modExp(y: BigNum, g: BigNum, x: BigNum, p: BigNum) -> Bool {
        y.bigInt = g.bigInt.power(x.bigInt, modulus: p.bigInt)
        return true
    }

    func bigEndianData() -> Data? {
        self.bigInt.serialize()
    }
}

// MARK: - RoyalVNCKit 1:1 DiffieHellmanKeyAgreement Implementation
fileprivate struct DiffieHellmanKeyAgreement {
    let publicKey: Data
    let privateKey: Data
    let secretKey: Data

    init?(prime: Data, generator: Data, peerKey: Data, keyLength: Int) {
        guard keyLength > 0 else { return nil }

        guard let keyPair = Self.generateKeyPair(generator: generator, prime: prime, keyLength: keyLength),
              !keyPair.privateKey.isEmpty,
              !keyPair.publicKey.isEmpty else {
            return nil
        }

        guard let secretKey = Self.computeSharedKey(prime: prime, peerKey: peerKey, privateKey: keyPair.privateKey, keyLength: keyLength),
              !secretKey.isEmpty else {
            return nil
        }

        self.publicKey = keyPair.publicKey
        self.privateKey = keyPair.privateKey
        self.secretKey = secretKey
    }

    struct KeyPair {
        let publicKey: Data
        let privateKey: Data
    }

    static func generateKeyPair(generator: Data, prime: Data, keyLength: Int) -> KeyPair? {
        let bigPrivKey = BigNum()
        let bigPubKey = BigNum()

        guard let bigPrime = BigNum(data: prime),
              let bigGenerator = BigNum(data: generator) else {
            return nil
        }

        repeat {
            let randSuccess = bigPrivKey.rand(range: bigPrime)
            guard randSuccess else { return nil }
        } while bigPrivKey.isZero

        let modSuccess = BigNum.modExp(y: bigPubKey, g: bigGenerator, x: bigPrivKey, p: bigPrime)
        guard modSuccess else { return nil }

        guard let privKeyBytes = bigPrivKey.bigEndianData(),
              let pubKeyBytes = bigPubKey.bigEndianData() else {
            return nil
        }

        return KeyPair(
            publicKey: pubKeyBytes.paddedToLength(keyLength),
            privateKey: privKeyBytes.paddedToLength(keyLength)
        )
    }

    static func computeSharedKey(prime: Data, peerKey: Data, privateKey: Data, keyLength: Int) -> Data? {
        guard let bigPrime = BigNum(data: prime),
              let bigPrivKey = BigNum(data: privateKey),
              let bigPeerKey = BigNum(data: peerKey) else {
            return nil
        }

        let bigSharedKey = BigNum()
        let modSuccess = BigNum.modExp(y: bigSharedKey, g: bigPeerKey, x: bigPrivKey, p: bigPrime)
        guard modSuccess else { return nil }

        guard let sharedKeyBytes = bigSharedKey.bigEndianData() else { return nil }
        return sharedKeyBytes.paddedToLength(keyLength)
    }
}

// MARK: - RoyalVNCKit 1:1 AES Encryption & Data Extension
fileprivate extension Data {
    func md5Hash() -> Data {
        return Data(Insecure.MD5.hash(data: self))
    }

    func paddedToLength(_ length: Int) -> Data {
        if self.count >= length {
            return self.prefix(length)
        }
        var padded = Data(repeating: 0, count: length - self.count)
        padded.append(self)
        return padded
    }
}

fileprivate struct AES128ECBEncryption {
    static func encrypt(data: Data, key: Data) -> Data? {
        guard key.count == 16 else { return nil }

        var input = data
        let rem = input.count % 16
        if rem != 0 {
            input.append(Data(repeating: 0, count: 16 - rem))
        }

        var ciphertext = Data(count: input.count)
        let ciphertextCount = ciphertext.count
        var numBytesEncrypted: Int = 0

        let status = ciphertext.withUnsafeMutableBytes { (cipherBuffer: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            input.withUnsafeBytes { (inputBuffer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyBuffer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    guard let cipherAddr = cipherBuffer.baseAddress,
                          let inputAddr = inputBuffer.baseAddress,
                          let keyAddr = keyBuffer.baseAddress else {
                        return CCCryptorStatus(kCCMemoryFailure)
                    }
                    return CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyAddr,
                        key.count,
                        nil,
                        inputAddr,
                        input.count,
                        cipherAddr,
                        ciphertextCount,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return ciphertext
    }
}

// MARK: - ARDAuthHelper
@objc public class ARDAuthHelper: NSObject {

    private static func log(_ message: String) {
        let level = UserDefaults.standard.object(forKey: "DiagnosticLoggingLevel") != nil ?
            UserDefaults.standard.integer(forKey: "DiagnosticLoggingLevel") :
            (UserDefaults.standard.bool(forKey: "EnableDiagnosticLogging") ? 1 : 0)
        if level >= 1 {
            NSLog("[Chicken] ARDAuthHelper: \(message)")
        }
    }

    @objc public static func performDiffieHellman(
        generator: Data,
        prime: Data,
        peerKey: Data,
        username: String,
        password: String
    ) -> ARDAuthResult? {
        let keyLength = prime.count
        log("Starting ARD Diffie-Hellman auth exchange...")

        var attempts = 0
        var dhAgreement: DiffieHellmanKeyAgreement? = nil
        while attempts < 1000 {
            attempts += 1
            if let agreement = DiffieHellmanKeyAgreement(prime: prime, generator: generator, peerKey: peerKey, keyLength: keyLength) {
                dhAgreement = agreement
                break
            }
        }

        guard let agreement = dhAgreement else {
            log("Error: DiffieHellmanKeyAgreement failed after 1000 attempts.")
            return nil
        }

        let secretHash = agreement.secretKey.md5Hash()

        let credArraySize = 128
        var creds = Data(count: credArraySize)

        let randomStatus = creds.withUnsafeMutableBytes { (credsBuffer: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let baseAddress = credsBuffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, credArraySize, baseAddress)
        }

        guard randomStatus == errSecSuccess else {
            log("Error: SecRandomCopyBytes failed.")
            return nil
        }

        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        let maxLength = 63
        let cappedUsername = cleanUsername.count > maxLength ? String(cleanUsername.prefix(maxLength)) : cleanUsername
        let cappedPassword = cleanPassword.count > maxLength ? String(cleanPassword.prefix(maxLength)) : cleanPassword

        log("Performing ARD auth for user '\(cappedUsername)' (KeyLength: \(keyLength) bytes)")

        let usernameC = cappedUsername.utf8CString
        let passwordC = cappedPassword.utf8CString

        let fillCredsSuccess = creds.withUnsafeMutableBytes { (credsBuffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let credsBytes = credsBuffer.baseAddress else { return false }

            let copyUsernameSuccess = usernameC.withUnsafeBytes { usernameCBytesPtr in
                guard let usernameCBytes = usernameCBytesPtr.baseAddress else { return false }
                credsBytes.copyMemory(from: usernameCBytes, byteCount: cappedUsername.utf8.count)
                return true
            }
            guard copyUsernameSuccess else { return false }

            let copyPasswordSuccess = passwordC.withUnsafeBytes { passwordCBytesPtr in
                guard let passwordCBytes = passwordCBytesPtr.baseAddress else { return false }
                let credsBytesStartingAtPassword = credsBytes.advanced(by: credArraySize / 2)
                credsBytesStartingAtPassword.copyMemory(from: passwordCBytes, byteCount: cappedPassword.utf8.count)
                return true
            }
            guard copyPasswordSuccess else { return false }

            return true
        }

        guard fillCredsSuccess else {
            log("Error: Filling creds failed.")
            return nil
        }

        creds[cappedUsername.utf8.count] = 0
        creds[(credArraySize / 2) + cappedPassword.utf8.count] = 0

        guard let cipherText = AES128ECBEncryption.encrypt(data: creds, key: secretHash) else {
            log("Error: AES encryption failed.")
            return nil
        }

        log("ARD Diffie-Hellman computation successful.")
        return ARDAuthResult(clientPublicKey: agreement.publicKey, encryptedCredentials: cipherText)
    }
}
