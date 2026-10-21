import Foundation
import MLX

/// Reads only requested tensors; never maps or loads an entire multi-gigabyte checkpoint.
final class TensorStore {
    struct Entry { let file: URL; let offset: UInt64; let count: Int; let shape: [Int]; let dtype: DType }
    private(set) var entries: [String: Entry] = [:]
    init(files: [URL]) throws {
        for file in files {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let first = try handle.read(upToCount: 8) ?? Data()
            guard first.count == 8 else { throw MossError.model("A model file is incomplete. Re-download it.") }
            let length = first.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            guard length > 1, length < 32 * 1024 * 1024 else { throw MossError.model("A model file has an invalid header.") }
            guard let bytes = try handle.read(upToCount: Int(length)), bytes.count == Int(length),
                  let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw MossError.model("A model file is damaged.") }
            let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            for (key, value) in header where key != "__metadata__" {
                guard let d = value as? [String: Any], let shape = d["shape"] as? [Int],
                      let offsets = d["data_offsets"] as? [Int], offsets.count == 2,
                      let type = d["dtype"] as? String else { throw MossError.model("Invalid model tensor: \(key).") }
                let types: [String: DType] = ["BF16": .bfloat16, "F32": .float32, "F16": .float16, "U32": .uint32, "I32": .int32, "I64": .int64, "U8": .uint8]
                guard let dtype = types[type], offsets[0] >= 0, offsets[1] >= offsets[0],
                      UInt64(offsets[1]) + length + 8 <= UInt64(fileSize), !shape.contains(where: { $0 < 0 }) else { throw MossError.model("Unsupported or damaged tensor: \(key).") }
                let widths = ["BF16": 2, "F32": 4, "F16": 2, "U32": 4, "I32": 4, "I64": 8, "U8": 1]
                var expected = widths[type]!
                for dimension in shape {
                    let product = expected.multipliedReportingOverflow(by: dimension)
                    guard !product.overflow else { throw MossError.model("Invalid tensor dimensions.") }; expected = product.partialValue
                }
                guard expected == offsets[1]-offsets[0], entries[key] == nil else { throw MossError.model("Duplicate or invalid tensor: \(key).") }
                entries[key] = Entry(file: file, offset: 8 + length + UInt64(offsets[0]), count: expected, shape: shape, dtype: dtype)
            }
        }
    }
    func read(_ name: String, row: Int? = nil) throws -> MLXArray {
        guard let e = entries[name] else { throw MossError.model("The model is missing \(name). Re-download it.") }
        var shape = e.shape, offset = e.offset, count = e.count
        if let row {
            guard !shape.isEmpty, row >= 0, row < shape[0] else { throw MossError.model("Invalid token in model file.") }
            count /= shape[0]; offset += UInt64(row * count); shape[0] = 1
        }
        let handle = try FileHandle(forReadingFrom: e.file); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw MossError.model("A model file could not be read. Keep it downloaded on this iPhone.") }
        return MLXArray(data, shape, dtype: e.dtype)
    }
    func load(prefix: String, excluding: String? = nil) throws -> Weights {
        var values: [String: MLXArray] = [:]
        for name in entries.keys.sorted() where name.hasPrefix(prefix) && !(excluding.map { name.hasPrefix($0) } ?? false) {
            values[String(name.dropFirst(prefix.count))] = try read(name)
        }
        return Weights(values)
    }
}

struct Weights {
    let values: [String: MLXArray]
    init(_ values: [String: MLXArray]) { self.values = values }
    func get(_ name: String) throws -> MLXArray {
        guard let w = values[name] else { throw MossError.model("Missing model weight: \(name).") }; return w
    }
    func linear(_ x: MLXArray, _ path: String, bits: Int, adapter: Weights? = nil) throws -> MLXArray {
        let w = try get(path + ".weight")
        var y: MLXArray
        if let scales = values[path + ".scales"] {
            y = quantizedMM(x, w, scales: scales, biases: values[path + ".biases"], groupSize: 64, bits: bits)
        } else { y = matmul(x.asType(w.dtype), w.T) }
        if let bias = values[path + ".bias"] { y = y + bias }
        if let adapter, let down = adapter.values[path + ".lora_down.weight"], let up = adapter.values[path + ".lora_up.weight"] {
            let alpha = adapter.values[path + ".alpha"]?.item(Float.self) ?? Float(down.shape[0])
            let delta = matmul(matmul(x.asType(.float32), down.T), up.T) * (alpha / Float(down.shape[0]))
            y = y + delta.asType(y.dtype)
        }
        return y
    }
    func norm(_ x: MLXArray, _ path: String, offset: Bool = false, eps: Float = 1e-6) throws -> MLXArray {
        let f = x.asType(.float32)
        let normalized = f * rsqrt(mean(f * f, axis: -1, keepDims: true) + eps)
        let weight = try get(path + ".weight")
        return offset ? (normalized * weight).asType(x.dtype) : normalized.asType(x.dtype) * weight
    }
}
func mossSilu(_ x: MLXArray) -> MLXArray { let f = x.asType(.float32); return (f * sigmoid(f)).asType(x.dtype) }
func mossSitu(_ h: MLXArray, _ g: MLXArray) -> MLXArray { (4 * tanh(g / 4) * sigmoid(g)) * (25 * tanh(h / 25)) }
