import Foundation

/// Encodes and decodes `HelperEnvelope`s as binary property lists (docs/v2/ADR-0008 §2). Strict,
/// because this is a security boundary: the size cap is checked before anything is parsed, only a
/// binary property list is accepted, the protocol version is checked before the body is decoded,
/// and anything that doesn't decode (truncated, an unknown case, a missing field) is a
/// `HelperFailure`, never a crash.
public enum HelperCodec {
    /// Messages over this are refused on both sides.
    public static let maximumBytes = 8 << 20
    static let magic = Data("bplist00".utf8)

    public static func encode<Body: Codable>(_ body: Body, build: String) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(HelperEnvelope(build: build, body: body))
        } catch {
            throw HelperFailure.malformed("couldn't encode \(Body.self): \(error)")
        }
        guard data.count <= maximumBytes else { throw HelperFailure.tooLarge(bytes: data.count) }
        return data
    }

    /// The body and the sender's build.
    public static func decode<Body: Codable>(_ type: Body.Type, from data: Data) throws -> (body: Body, build: String) {
        guard data.count <= maximumBytes else { throw HelperFailure.tooLarge(bytes: data.count) }
        guard data.starts(with: magic) else { throw HelperFailure.malformed("not a binary property list") }
        do {
            let checked = try PropertyListDecoder().decode(Checked<Body>.self, from: data)
            return (checked.body, checked.build)
        } catch let failure as HelperFailure {
            throw failure
        } catch let error as DecodingError {
            throw HelperFailure.malformed(describe(error))
        } catch {
            throw HelperFailure.malformed("\(error)".prefix(300).description)
        }
    }

    /// `HelperEnvelope`'s layout, reading the version first: a message from another version is
    /// refused as a mismatch, whatever its body holds.
    private struct Checked<Body: Codable>: Decodable {
        let build: String
        let body: Body

        enum CodingKeys: String, CodingKey {
            case protocolVersion, build, body
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .protocolVersion)
            guard version == HelperProtocol.protocolVersion else {
                throw HelperFailure.versionMismatch(received: version, expected: HelperProtocol.protocolVersion)
            }
            build = String(try container.decode(String.self, forKey: .build).prefix(64))
            body = try container.decode(Body.self, forKey: .body)
        }
    }

    /// Where decoding stopped and why; never the payload itself.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        let text: String
        switch error {
        case .typeMismatch(_, let context): text = "wrong type at \(path(context))"
        case .valueNotFound(_, let context): text = "missing value at \(path(context))"
        case .keyNotFound(let key, let context): text = "missing \(key.stringValue) at \(path(context))"
        case .dataCorrupted(let context): text = "\(context.debugDescription) at \(path(context))"
        @unknown default: text = "\(error)"
        }
        return String(text.prefix(300))
    }
}
