import CryptoKit
import Foundation

public enum CRMProvider: String, Codable, CaseIterable, Sendable { case hubSpot, salesforce }
public enum CRMObjectType: String, Codable, CaseIterable, Sendable { case contact, company, task }
public enum CRMWriteMode: String, Codable, Sendable { case create, update }

public struct CRMConnectionDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var provider: CRMProvider
    public var displayName: String
    public var clientID: String
    public var redirectURI: URL
    public var tokenBrokerURL: URL?
    public init(id: UUID = UUID(), provider: CRMProvider, displayName: String, clientID: String,
                redirectURI: URL, tokenBrokerURL: URL? = nil) {
        self.id = id; self.provider = provider; self.displayName = displayName
        self.clientID = clientID; self.redirectURI = redirectURI; self.tokenBrokerURL = tokenBrokerURL
    }
    public var externalSetupBlocker: String? {
        if provider == .hubSpot {
            guard let broker = tokenBrokerURL,
                  broker.scheme?.lowercased() == "https",
                  broker.host?.isEmpty == false,
                  broker.user == nil,
                  broker.password == nil,
                  broker.query == nil,
                  broker.fragment == nil
            else {
            return "HubSpot requires a client secret for code exchange and refresh. Configure an HTTPS token broker; the secret must never enter the Mac app."
            }
        }
        return nil
    }
}

public struct CRMFieldMapping: Codable, Equatable, Sendable {
    public let object: CRMObjectType
    public var fields: [String: String]
    public init(object: CRMObjectType, fields: [String: String]) throws {
        let allowed = Self.allowedFields[object] ?? []
        guard !fields.isEmpty, fields.keys.allSatisfy(allowed.contains),
              fields.values.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.utf8.count <= 16_384
              })
        else { throw CRMConnectorError.invalidMapping }
        self.object = object; self.fields = fields
    }
    public static let allowedFields: [CRMObjectType: Set<String>] = [
        .contact: ["email", "firstName", "lastName", "phone", "companyName", "jobTitle"],
        .company: ["name", "domain", "phone", "website"],
        .task: ["subject", "body", "dueAt", "status", "priority", "relatedRecordID"],
    ]
}

public struct CRMWriteReview: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let connectionID: UUID
    public let provider: CRMProvider
    public let object: CRMObjectType
    public let mode: CRMWriteMode
    public let existingProviderID: String?
    public let mapping: CRMFieldMapping
    public let sourceFingerprint: String
    public init(id: UUID = UUID(), connectionID: UUID, provider: CRMProvider,
                object: CRMObjectType, mode: CRMWriteMode, existingProviderID: String? = nil,
                mapping: CRMFieldMapping, sourceFingerprint: String) throws {
        let providerIDPattern = "^[A-Za-z0-9_-]{1,128}$"
        guard mode == .create
                || existingProviderID?.range(of: providerIDPattern, options: .regularExpression) != nil
        else {
            throw CRMConnectorError.missingUpdateTarget
        }
        guard mapping.object == object,
              !sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceFingerprint.utf8.count <= 256
        else { throw CRMConnectorError.invalidMapping }
        if mode == .create {
            switch object {
            case .contact:
                guard mapping.fields["email"]?.isEmpty == false
                        || mapping.fields["phone"]?.isEmpty == false
                else { throw CRMConnectorError.missingDuplicateKey }
                if provider == .salesforce {
                    guard mapping.fields["lastName"]?.isEmpty == false else {
                        throw CRMConnectorError.invalidMapping
                    }
                }
            case .company:
                let key = provider == .hubSpot ? "domain" : "name"
                guard mapping.fields[key]?.isEmpty == false else {
                    throw CRMConnectorError.missingDuplicateKey
                }
            case .task:
                break
            }
        }
        self.id = id; self.connectionID = connectionID; self.provider = provider
        self.object = object; self.mode = mode; self.existingProviderID = existingProviderID
        self.mapping = mapping; self.sourceFingerprint = sourceFingerprint
    }
    public var idempotencyKey: String {
        let fields = mapping.fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1f}")
        let input = [connectionID.uuidString, provider.rawValue, object.rawValue, mode.rawValue,
                     existingProviderID ?? "", sourceFingerprint, fields].joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CRMWriteOutcome: Equatable, Sendable {
    case succeeded(providerID: String, deepLink: URL?)
    case duplicate(providerID: String, deepLink: URL?)
    case rateLimited(retryAfter: Date?)
    case reconciliationRequired(idempotencyKey: String)
    case reconnectRequired
    case failed(String)
}

public enum CRMConnectorError: Error, Equatable, LocalizedError, Sendable {
    case invalidMapping, missingUpdateTarget, missingDuplicateKey
    case connectionNotConfigured, ineligibleSource
    public var errorDescription: String? {
        switch self {
        case .invalidMapping: "Use only the reviewed fields supported for this CRM object."
        case .missingUpdateTarget: "An update requires the reviewed provider record ID."
        case .missingDuplicateKey: "A new Contact needs an email or phone. A new HubSpot Company needs a domain; a new Salesforce Company needs a name."
        case .connectionNotConfigured: "Complete the provider's external OAuth setup first."
        case .ineligibleSource: "Sensitive, private, located, file, rich, image, or Vault content cannot be sent to CRM."
        }
    }
}
