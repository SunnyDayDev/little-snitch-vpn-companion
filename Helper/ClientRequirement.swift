import CryptoKit
import Foundation
import Security
import os

/// Code-signing requirement, которому обязан удовлетворять XPC-клиент
/// (§10.2 SPEC.md). Строится из подписи самого helper: «клиент подписан тем же
/// сертификатом, что и я, и его bundle id — приложение».
///
/// При ad-hoc подписи (сборка без самоподписанного сертификата) сертификата
/// нет вовсе, и строгий requirement не собирается. В этом случае действует
/// задокументированный fallback — проверка только по identifier — и в лог
/// уходит предупреждение: гарантия ниже, режим годится лишь для разработки
/// (риск в design.md).
enum ClientRequirement {
    struct Built {
        let requirement: String
        let isStrict: Bool
    }

    private static let logger = Logger(subsystem: HelperConstants.machServiceName,
                                       category: "security")

    static func build(appBundleID: String = "dev.sunnyday.lsvpncompanion") -> Built {
        guard let hash = ownLeafCertificateHash() else {
            logger.warning("""
                helper подписан ad-hoc: строгий requirement недоступен, \
                проверяем клиента только по identifier
                """)
            return Built(requirement: "identifier \"\(appBundleID)\"", isStrict: false)
        }
        return Built(
            requirement: "identifier \"\(appBundleID)\" and certificate leaf = H\"\(hash)\"",
            isStrict: true)
    }

    /// SHA-1 DER-представления листового сертификата собственной подписи —
    /// именно в этом виде его ждёт синтаксис requirement (`H"…"`).
    private static func ownLeafCertificateHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }

        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
