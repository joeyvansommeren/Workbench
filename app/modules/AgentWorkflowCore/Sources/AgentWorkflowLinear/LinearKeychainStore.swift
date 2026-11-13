import Foundation
import Security

/// Reads and writes the Linear personal API key in the macOS Keychain.
public enum LinearKeychainStore {
  public static let service = "com.joeyvansommeren.Workbench.linear"

  public static func apiKey() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  public static func setApiKey(_ key: String) -> Bool {
    deleteApiKey()
    let data = Data(key.utf8)
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecValueData as String: data,
    ]
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  @discardableResult
  public static func deleteApiKey() -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
