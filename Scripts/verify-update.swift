import CryptoKit
import Foundation

private struct VerificationFailure: Error {
    let reason: String
}

/// 读应用公钥，校验发布目录里的清单、安装包和公开下载地址。
private func verify(plist: URL, directory: URL, downloadURL: String) throws {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil)
    guard let info = info as? [String: Any], let publicKey = info["SUPublicEDKey"] as? String,
          let keyBytes = Data(base64Encoded: publicKey),
          let buildVersion = info["CFBundleVersion"] as? String,
          let releaseVersion = info["CFBundleShortVersionString"] as? String else {
        throw VerificationFailure(reason: "应用缺少有效的更新公钥或版本信息")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let feed = try Data(contentsOf: directory.appendingPathComponent("appcast.xml"))
    guard let marker = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards) else {
        throw VerificationFailure(reason: "更新清单缺少签名")
    }
    // Sparkle 只签署签名块之前的原始字节。
    let fields = String(decoding: feed[marker.upperBound...], as: UTF8.self).split(separator: "\n")
    let signedFeed = feed.prefix(marker.lowerBound)
    guard fields.count == 3, fields[2] == "-->", fields[0].hasPrefix("edSignature: "),
          fields[1].hasPrefix("length: "), Int(fields[1].dropFirst(8)) == signedFeed.count,
          let signature = Data(base64Encoded: String(fields[0].dropFirst(13))),
          key.isValidSignature(signature, for: signedFeed) else {
        throw VerificationFailure(reason: "更新清单签名无效")
    }

    let xml = try XMLDocument(data: feed, options: [.nodeLoadExternalEntitiesNever])
    let items = try xml.nodes(forXPath: "/rss/channel/item")
    guard items.count == 1, let item = items.first as? XMLElement,
          item.elements(forName: "sparkle:version").first?.stringValue == buildVersion,
          item.elements(forName: "sparkle:shortVersionString").first?.stringValue == releaseVersion,
          let enclosure = item.elements(forName: "enclosure").first,
          enclosure.attribute(forName: "url")?.stringValue == downloadURL,
          let lengthValue = enclosure.attribute(forName: "length")?.stringValue,
          let length = Int(lengthValue),
          let signatureValue = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let archiveSignature = Data(base64Encoded: signatureValue) else {
        throw VerificationFailure(reason: "更新清单的版本、下载地址或安装包信息不匹配")
    }
    let archive = try Data(contentsOf: directory.appendingPathComponent("PrismPulse-macOS.zip"))
    guard archive.count == length, key.isValidSignature(archiveSignature, for: archive) else {
        throw VerificationFailure(reason: "安装包的长度或签名无效")
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("用法：swift Scripts/verify-update.swift Info.plist 发布目录 下载地址\n", stderr)
    exit(64)
}
do {
    try verify(plist: URL(fileURLWithPath: CommandLine.arguments[1]),
               directory: URL(fileURLWithPath: CommandLine.arguments[2]),
               downloadURL: CommandLine.arguments[3])
    print("更新清单和安装包的签名已通过公钥校验")
} catch let error as VerificationFailure {
    fputs("\(error.reason)\n", stderr)
    exit(1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
