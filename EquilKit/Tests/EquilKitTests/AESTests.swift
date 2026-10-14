import XCTest
@testable import EquilKit

final class AESTests: XCTestCase {

    func testEquilPasswordLength() {
        // 32 字节 = deriveKey("Equil") + deriveKey(password)
        XCTAssertEqual(EquilAES.equilPassword("1234").count, 32)
    }

    func testEquilPasswordDerivation() {
        // deriveKey = SHA256(password)[2..<18]
        let derived = EquilAES.deriveKey("Equil")
        XCTAssertEqual(derived.count, 16)
        let digest = EquilAES.sha256(Array("Equil".utf8))
        XCTAssertEqual(derived, Array(digest[2..<18]))
    }

    func testEncryptDecryptRoundTrip() throws {
        let key = EquilAES.equilPassword("abcd")
        let plaintext: [UInt8] = [0x0A, 0x00, 0x00, 0x00, 0x01, 0x04, 0x28, 0x00]
        let model = try EquilAES.encrypt(key: key, data: plaintext)
        XCTAssertEqual(Hex.decode(model.iv!).count, 12, "GCM IV 应为 12 字节")
        XCTAssertEqual(Hex.decode(model.tag!).count, 16, "GCM 认证标签应为 16 字节")
        XCTAssertEqual(Hex.decode(model.ciphertext!).count, plaintext.count, "GCM 密文长度等于明文长度")

        let recovered = try EquilAES.decrypt(model, key: key)
        XCTAssertEqual(recovered, Hex.encode(plaintext))
    }

    func testDecryptWithWrongKeyThrows() throws {
        let model = try EquilAES.encrypt(key: EquilAES.equilPassword("right"), data: [0x01, 0x02, 0x03])
        XCTAssertThrowsError(try EquilAES.decrypt(model, key: EquilAES.equilPassword("wrong")))
    }
}