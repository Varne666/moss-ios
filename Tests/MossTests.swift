import XCTest
@testable import Moss

final class MossTests: XCTestCase {
    private func fixture<T:Decodable>(_ name:String,as type:T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:name,withExtension:"json"))
        return try JSONDecoder().decode(type,from:Data(contentsOf:url))
    }
    struct Sampling: Decodable {
        struct Schedule: Decodable { let steps:Int; let shift:Float; let values:[Float] }
        struct Noise: Decodable { let seed:UInt32; let values:[Float] }
        let schedules:[Schedule]; let noise:[Noise]
    }
    struct Tokens: Decodable { let prompt:String; let formatted:String; let ids:[Int] }
    func testSchedulerAgainstReference() throws {
        let cases = try fixture("sampling-fixtures",as:Sampling.self)
        for sample in cases.schedules {
            let actual = MossSchedule.sigmas(steps:sample.steps,shift:sample.shift)
            XCTAssertEqual(actual.map(\.bitPattern),sample.values.map(\.bitPattern))
            XCTAssertEqual(actual.last,0)
            for i in 1..<actual.count { XCTAssertLessThan(actual[i],actual[i-1]) }
        }
    }
    func testSeededNoiseAgainstReference() throws {
        let cases = try fixture("sampling-fixtures",as:Sampling.self)
        for sample in cases.noise {
            var generator = MossNoise(seed:sample.seed)
            let actual = generator.normal(count:sample.values.count)
            for (a,b) in zip(actual,sample.values) { XCTAssertEqual(a,b,accuracy:0.000003) }
        }
    }
    func testOfficialTokenizer() throws {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"tokenizer",withExtension:"json"))
        let tokenizer = try MossTokenizer(url:url)
        for sample in try fixture("tokenizer-fixtures",as:[Tokens].self) {
            XCTAssertEqual(MossTokenizer.formatted(sample.prompt),sample.formatted)
            XCTAssertEqual(try tokenizer.encode(sample.prompt),sample.ids,sample.prompt)
        }
    }
    func testBestPresetAndSizeValidation() throws {
        var settings = GenerationSettings(); settings.prompt = "a cat"; settings.preset(.best)
        XCTAssertEqual(settings.steps,50); XCTAssertEqual(settings.guidance,3); XCTAssertEqual(settings.shift,5); XCTAssertTrue(settings.skipLayer)
        XCTAssertNoThrow(try settings.validate())
        settings.width = 513; XCTAssertThrowsError(try settings.validate())
        settings.width = 1536; settings.height = 1536; XCTAssertThrowsError(try settings.validate())
    }
    func testManifestRejectsChangedWeightsAndUnsafePaths() throws {
        let manifest = try ModelManifest.bundled(); XCTAssertNoThrow(try manifest.validate())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(manifest)) as? [String:Any])
        var files = try XCTUnwrap(json["files"] as? [[String:Any]])
        files[0]["path"] = "../outside"; json["files"] = files
        let invalid = try JSONDecoder().decode(ModelManifest.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertThrowsError(try invalid.validate())
    }
    func testFileIntegrityRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("test.bin"); try Data("abc".utf8).write(to:url)
        let file = ModelFile(path:"test.bin",url:URL(string:"https://example.com/model")!,bytes:3,sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",component:"text")
        XCTAssertTrue(try ModelManager.valid(file,in:directory))
        try Data("abd".utf8).write(to:url); XCTAssertFalse(try ModelManager.valid(file,in:directory))
    }
}
