import Foundation

/// The official tokenizer's NFC, regex pre-tokenizer, byte-level BPE, and added tokens.
final class MossTokenizer {
    private let vocabulary: [String: Int]
    private var ranks: [String: Int] = [:]
    private let split: NSRegularExpression
    private let specials: NSRegularExpression
    private let added: [String: Int]
    private let byteMap: [UInt8: String]
    init(url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = root["model"] as? [String: Any], let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [[String]] else { throw MossError.model("The tokenizer is incomplete. Re-download the model.") }
        vocabulary = vocab
        for (i, pair) in merges.enumerated() where pair.count == 2 { ranks[pair[0] + "\u{0}" + pair[1]] = i }
        let tokens = (root["added_tokens"] as? [[String: Any]] ?? []).compactMap { d -> (String, Int)? in
            guard let text = d["content"] as? String, let id = d["id"] as? Int else { return nil }; return (text, id)
        }
        added = Dictionary(uniqueKeysWithValues: tokens)
        specials = try NSRegularExpression(pattern: tokens.map { $0.0 }.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"))
        // The official tokenizer is Sequence[Split(Regex, Isolated), ByteLevel(use_regex: false)].
        guard let pretok = root["pre_tokenizer"] as? [String: Any],
              let items = pretok["pretokenizers"] as? [[String: Any]],
              let first = items.first, first["type"] as? String == "Split",
              let pattern = (first["pattern"] as? [String: String])?["Regex"] else {
            throw MossError.model("The tokenizer format is not supported. Re-download the model.")
        }
        split = try NSRegularExpression(pattern: pattern)
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codes = bytes; var n = 0
        for b in 0...255 where !bytes.contains(b) { bytes.append(b); codes.append(256+n); n += 1 }
        byteMap = Dictionary(uniqueKeysWithValues: zip(bytes, codes).map { pair in (UInt8(pair.0), String(UnicodeScalar(pair.1)!)) })
    }
    static func formatted(_ prompt: String) -> String {
        // The released chat template trims outer whitespace. The stored user prompt remains verbatim.
        "<|im_start|>user\n" + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "<|im_end|>\n<|im_start|>assistant\n<think>\n"
    }
    func encode(_ prompt: String) throws -> [Int] {
        let text = Self.formatted(prompt)
        let ns = text as NSString
        var output: [Int] = []; var cursor = 0
        for match in specials.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { try encodeOrdinary(ns.substring(with: NSRange(location: cursor, length: match.range.location-cursor)), into: &output) }
            if let id = added[ns.substring(with: match.range)] { output.append(id) }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { try encodeOrdinary(ns.substring(from: cursor), into: &output) }
        guard output.count <= 4096 else { throw MossError.model("This prompt is longer than the model can read. Shorten it to fewer than 4,096 tokens; your text has not been changed.") }
        return output
    }
    private func encodeOrdinary(_ raw: String, into output: inout [Int]) throws {
        let text = raw.precomposedStringWithCanonicalMapping; let ns = text as NSString
        // Split with "Isolated" behaviour keeps the text between matches as its own pieces.
        var pieces: [String] = []; var cursor = 0
        for match in split.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            if match.range.length > 0 { pieces.append(ns.substring(with: match.range)) }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { pieces.append(ns.substring(from: cursor)) }
        for piece in pieces {
            var parts = piece.utf8.map { byteMap[$0]! }
            while parts.count > 1 {
                var best: Int?, rank = Int.max
                for i in 0..<(parts.count-1) {
                    if let r = ranks[parts[i] + "\u{0}" + parts[i+1]], r < rank { best = i; rank = r }
                }
                guard let i = best else { break }
                parts[i] += parts[i+1]; parts.remove(at: i+1)
            }
            for part in parts {
                guard let id = vocabulary[part] else { throw MossError.model("The tokenizer does not match this model. Re-download the model.") }
                output.append(id)
            }
        }
    }
}
