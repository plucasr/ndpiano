import Foundation
import JavaScriptCore

/// Bridge to the embedded OpenNord nsmp decoders (bundled JS, all codec generations).
/// One JS context per process; calls are serialized with a lock — decode off the audio thread.
public final class NsmpBridge: @unchecked Sendable {
    public struct Zone {
        public let keyLow: Int
        public let keyHigh: Int
        public let rootKey: Int
        public let velLow: Int
        public let velTop: Int
        public let globalID: Int
    }

    public struct Stroke {
        public let channels: [[Float]]
        public let sampleRate: Double
        public let loopStart: Int? // frames from stroke start; loop runs to the stroke's end
        public let decayDbPerSecond: Double
    }

    public struct File {
        public let handle: Int
        public let name: String
        public let version: String
        public let codec: Int
        public let zones: [Zone]
    }

    public static let shared = NsmpBridge()

    private let ctx = JSContext()!
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.module.url(forResource: "decoder", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("nordpiano: decoder.js missing from bundle")
        }
        ctx.exceptionHandler = { _, e in
            fputs("nordpiano: JS error: \(e?.toString() ?? "?")\n", stderr)
        }
        ctx.evaluateScript(script)
    }

    private func b64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// Parse a sample file's zones; keeps the bytes in the JS heap for stroke decode.
    public func load(bytes: [UInt8]) throws -> File {
        lock.lock(); defer { lock.unlock() }
        guard let fn = ctx.objectForKeyedSubscript("NordDecode")?
            .objectForKeyedSubscript("loadFile") else { throw NSError(domain: "nordpiano", code: 10) }
        let result = fn.call(withArguments: [b64(Data(bytes))])?.toString()
        guard let result, let data = result.data(using: .utf8) else { throw NSError(domain: "nordpiano", code: 11) }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return File(
            handle: json["handle"] as! Int,
            name: json["name"] as! String,
            version: json["version"] as! String,
            codec: json["codec"] as! Int,
            zones: (json["zones"] as! [[String: Any]]).map {
                Zone(keyLow: $0["keyLow"] as! Int, keyHigh: $0["keyHigh"] as! Int,
                     rootKey: $0["rootKey"] as! Int, velLow: $0["velLow"] as! Int,
                     velTop: $0["velTop"] as! Int, globalID: $0["globalID"] as! Int)
            })
    }

    public func decodeStroke(handle: Int, globalID: Int) throws -> Stroke {
        lock.lock(); defer { lock.unlock() }
        guard let fn = ctx.objectForKeyedSubscript("NordDecode")?
            .objectForKeyedSubscript("decodeStroke") else { throw NSError(domain: "nordpiano", code: 10) }
        guard let result = fn.call(withArguments: [handle, globalID])?.toString(),
              let data = result.data(using: .utf8) else { throw NSError(domain: "nordpiano", code: 12) }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = json["frames"] as! Int
        let channels = (json["channels"] as! [String]).map { b64 -> [Float] in
            var floats = [Float](repeating: 0, count: frames)
            Data(base64Encoded: b64)!.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(&floats, base, min(frames * 4, raw.count))
                }
            }
            return floats
        }
        let loop = json["loop"] as? [String: Any]
        return Stroke(
            channels: channels,
            sampleRate: json["sampleRate"] as! Double,
            loopStart: (loop?["loops"] as? Bool == true) ? (loop?["loopStart"] as? Int) : nil,
            decayDbPerSecond: loop?["decayDbPerSecond"] as? Double ?? 0)
    }

    public func release(handle: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = ctx.objectForKeyedSubscript("NordDecode")?
            .objectForKeyedSubscript("release")?
            .call(withArguments: [handle])
    }
}
