import Foundation
import CryptoKit

/// AES-GCM 加解密，对照 AndroidAPS `manager/AESUtil.kt`。
///
/// AAPS 用 `AES/GCM/NoPadding` + 12 字节随机 IV + 128 位认证标签，
/// 与 CryptoKit 的 `AES.GCM`（12 字节 nonce、16 字节 tag）语义一致，可直接对应。
public enum EquilAES {

    /// 对照 `generateAESKeyFromPassword`：SHA-256(password) 取 [2..18) 共 16 字节。
    static func deriveKey(_ password: String) -> [UInt8] {
        let digest = SHA256.hash(data: Data(password.utf8))
        return Array(Array(digest)[2..<18])
    }

    /// 对照 `getEquilPassWord`：32 字节 = deriveKey("Equil") + deriveKey(password)。
    /// CmdPair 用它作为初始握手密钥材料。
    public static func equilPassword(_ password: String) -> [UInt8] {
        deriveKey("Equil") + deriveKey(password)
    }

    /// SHA-256 摘要，对照 CmdPair 里 `MessageDigest.getInstance("SHA-256")`。
    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    /// 对照 `aesEncrypt`：随机 12 字节 IV，返回 tag / iv / ciphertext（均大写十六进制）。
    public static func encrypt(key: [UInt8], data: [UInt8]) throws -> EquilCmdModel {
        let symmetricKey = SymmetricKey(data: Data(key))
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(data), using: symmetricKey, nonce: nonce)
        var model = EquilCmdModel()
        model.iv = Hex.encode(nonce.withUnsafeBytes { Array($0) })
        model.tag = Hex.encode(Array(sealed.tag))
        model.ciphertext = Hex.encode(Array(sealed.ciphertext))
        return model
    }

    /// 对照 `decrypt`：返回明文的大写十六进制字符串（AAPS 后续按字符下标切分）。
    public static func decrypt(_ model: EquilCmdModel, key: [UInt8]) throws -> String {
        guard let ivHex = model.iv, let ctHex = model.ciphertext, let tagHex = model.tag else {
            throw EquilError.badCipherModel
        }
        let nonce = try AES.GCM.Nonce(data: Data(Hex.decode(ivHex)))
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(Hex.decode(ctHex)),
            tag: Data(Hex.decode(tagHex))
        )
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: Data(key)))
        return Hex.encode(Array(plain))
    }
}