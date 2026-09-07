import CoreML
import Embeddings
import XCTest
@testable import VecKit

final class BertBatchDiagnosisTests: XCTestCase {
    func testAttentionMaskPrecisionProbe() async throws {
        for repo in ["thenlper/gte-base", "mixedbread-ai/mxbai-embed-large-v1", "BAAI/bge-base-en-v1.5", "intfloat/e5-base-v2"] {
            let bundle = try await Bert.loadModelBundle(from: repo)
            let tokens = try bundle.tokenizer.tokenizeText("The trademark deal closed at 1.5 million.", maxLength: 512)
            let input = MLTensor(shape: [1, tokens.count], scalars: tokens)
            let floatMask = MLTensor(shape: [1, tokens.count], scalars: Array(repeating: Float(1), count: tokens.count))
            let halfMask = floatMask.cast(to: Float16.self)
            let noMask = bundle.model(inputIds: input).sequenceOutput
            let withFloat = bundle.model(inputIds: input, attentionMask: floatMask).sequenceOutput
            let withHalf = bundle.model(inputIds: input, attentionMask: halfMask).sequenceOutput
            let a = l2Normalize(await noMask[0, 0, 0...].cast(to: Float.self).shapedArray(of: Float.self).scalars)
            let b = l2Normalize(await withFloat[0, 0, 0...].cast(to: Float.self).shapedArray(of: Float.self).scalars)
            let c = l2Normalize(await withHalf[0, 0, 0...].cast(to: Float.self).shapedArray(of: Float.self).scalars)
            let floatCos = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let halfCos = zip(a, c).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            print("PRECISION \(repo) noMask=\(noMask.scalarType) floatMask=\(withFloat.scalarType) halfMask=\(withHalf.scalarType) floatCos=\(floatCos) halfCos=\(halfCos)")
        }
    }

    func testGTEInputAndMaskProbe() async throws {
        let bundle = try await Bert.loadModelBundle(from: "thenlper/gte-base")
        let text = "The trademark deal closed at 1.5 million."
        let filler = String(repeating: "A longer unrelated passage about computers and weather. ", count: 20)
        let tokens = try bundle.tokenizer.tokenizeText(text, maxLength: 512)
        let batch = try bundle.tokenizer.tokenizeTextsPaddingToLongest([text, filler], padTokenId: 0, maxLength: 512)
        XCTAssertEqual(Array(batch.tokens.prefix(tokens.count)), tokens)
        print("PROBE tokens \(tokens.count) batch \(batch.shape)")
        func values(_ tensor: MLTensor) async -> [Float] {
            await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        }
        func cosine(_ a: [Float], _ b: [Float]) -> Double {
            let a = l2Normalize(a), b = l2Normalize(b)
            return zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
        }
        let single = await values(try bundle.encode(text))
        let maskedSingle = await values(try bundle.batchEncode([text]))
        let identicalBatch = await values(try bundle.batchEncode([text, text]))
        let mixedBatch = await values(try bundle.batchEncode([text, filler]))
        print("PROBE masked single \(cosine(single, maskedSingle)) identical batch \(cosine(single, Array(identicalBatch.prefix(768)))) mixed batch \(cosine(single, Array(mixedBatch.prefix(768))))")
        let input = MLTensor(shape: batch.shape, scalars: batch.tokens)
        let mask = MLTensor(shape: batch.shape, scalars: batch.attentionMask)
        let sequence = bundle.model(inputIds: input, attentionMask: mask).sequenceOutput
        let all = await values(sequence)
        print("PROBE full sequence \(sequence.shape) first token \(cosine(single, Array(all.prefix(768))))")
        XCTAssertGreaterThanOrEqual(cosine(single, maskedSingle), 0.9999)
        XCTAssertGreaterThanOrEqual(cosine(single, Array(identicalBatch.prefix(768))), 0.9999)
        XCTAssertGreaterThanOrEqual(cosine(single, Array(mixedBatch.prefix(768))), 0.9999)
    }

    func testPrefixedBatchUsesSameCharacterBudgetAsSingle() {
        let text = String(repeating: "a", count: 2_100)
        let expected = String(("passage: " + text).prefix(E5BaseEmbedder.maxInputCharacters))
        let batch = normalizeBertInputs([text], prefix: "passage: ", maxChars: E5BaseEmbedder.maxInputCharacters)
        XCTAssertEqual(batch.liveInputs.first?.count, expected.count)
        XCTAssertTrue(batch.liveInputs.first == expected)
    }
}
