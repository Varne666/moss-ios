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
    func testCountdownUsesMeasuredStepsAndPauses() {
        var settings = GenerationSettings(); settings.prompt = "a cat"; settings.preset(.fast)
        var clock = GenerationClock(plan:.init(settings:settings),calibration:.init())
        clock.record(.init(stage:.encode,index:0,total:32,message:""),at:0)
        XCTAssertNil(clock.remaining(at:1), "No number before anything is measured")
        clock.record(.init(stage:.prepare,index:0,total:1,message:""),at:20)
        for i in 0...3 { clock.record(.init(stage:.sample,index:i,total:8,message:""),at:30 + Double(i) * 10) }
        // 3 of 8 steps done at 10 s each (first dropped as warm-up), 5 left, decode guessed at 0.6 step.
        XCTAssertEqual(clock.remaining(at:60) ?? -1, 5 * 10 + 6, accuracy:0.01)
        clock.pause(at:60)
        XCTAssertEqual(clock.remaining(at:500) ?? -1, 56, accuracy:0.01, "Paused time does not count")
        clock.resume(at:500)
        XCTAssertEqual(clock.remaining(at:505) ?? -1, 51, accuracy:0.01)
        let learned = clock.calibrated()
        XCTAssertEqual(learned.encode[1] ?? -1, 20, accuracy:0.01)
        XCTAssertEqual(learned.steps.last?.seconds ?? -1, 10, accuracy:0.01)
        // A later, larger guided run is estimated before it starts.
        var best = settings; best.preset(.best)
        let next = GenerationClock(plan:.init(settings:best),calibration:learned)
        XCTAssertNil(next.remaining(at:0), "No encode timing yet for two prompts")
        var fast2 = GenerationClock(plan:.init(settings:settings),calibration:learned)
        XCTAssertNotNil(fast2.remaining(at:0))
        fast2.record(.init(stage:.encode,index:0,total:32,message:""),at:0)
        XCTAssertNotNil(fast2.remaining(at:1))
    }
    func testLoRAKeyLayouts() {
        XCTAssertEqual(LoRAFile.parse("diffusion_model.layers.3.proj.q.lora_down.weight")?.0, 3)
        XCTAssertEqual(LoRAFile.parse("diffusion_model.layers.3.proj.q.lora_down.weight")?.2, "down")
        XCTAssertEqual(LoRAFile.parse("transformer.layers.41.proj.ffn_up_gate.lora_B.weight")?.1, "ffn_up_gate")
        XCTAssertEqual(LoRAFile.parse("transformer.layers.41.proj.ffn_up_gate.lora_B.weight")?.2, "up")
        XCTAssertEqual(LoRAFile.parse("layers.0.proj.qkv.alpha")?.2, "alpha")
        XCTAssertEqual(LoRAFile.parse("lora_unet_layers_12_proj_ffn_down.lora_up.weight")?.0, 12)
        XCTAssertEqual(LoRAFile.parse("lora_unet_layers_12_proj_ffn_down.lora_up.weight")?.1, "ffn_down")
        XCTAssertNil(LoRAFile.parse("diffusion_model.text_embedder.blocks.0.qkv.lora_down.weight"))
        XCTAssertNil(LoRAFile.parse("diffusion_model.layers.3.norm1.weight"))
    }
    func testOldGalleryRecordsStillDecode() throws {
        let old = #"{"prompt":"a cat","negativePrompt":"","width":512,"height":512,"quality":"Balanced","steps":20,"guidance":3,"shift":5,"skipLayer":true,"seed":7,"lockedSeed":false,"count":1}"#
        let s = try JSONDecoder().decode(GenerationSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.width, 512); XCTAssertEqual(s.model, .base); XCTAssertTrue(s.loras.isEmpty); XCTAssertFalse(s.snapshotStyle)
        var snap = s; snap.snapshotStyle = true
        XCTAssertTrue(snap.effectivePrompt.hasPrefix(SnapshotStyle.prefix)); XCTAssertTrue(snap.effectivePrompt.contains("a cat"))
        XCTAssertEqual(s.effectivePrompt, "a cat")
    }
    func testLoRANames() {
        XCTAssertEqual(LoRAStore.friendlyName("MOSSRealisticSnapshotV1_3311349"), "Realistic Snapshot V1")
    }
}
