import Foundation
import CryptoKit

/// 证书指纹 / 绑定管理。
/// 存储信任的证书 SHA-256 指纹，用于自签名/私有 CA 的证书绑定（不全局关闭 ATS）。
public enum CertificateService {
    public static let store = KeychainStore()

    /// 计算给定数据的 SHA-256 指纹（hex 小写）。
    public static func sha256Fingerprint(ofData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 保存受信任指纹。
    public static func saveTrustedFingerprint(_ fingerprint: String) {
        try? store.save(fingerprint, for: .trustFingerprint)
    }

    /// 读取受信任指纹。
    public static func trustedFingerprint() -> String? {
        store.read(.trustFingerprint)
    }

    /// 移除信任。
    public static func clearTrust() {
        try? store.delete(.trustFingerprint)
    }
}
