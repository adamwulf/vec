import Foundation

/// L2-normalize a vector in place and return the result. `Bert.ModelBundle.encode`
/// returns CLS-token output without normalization, so BERT-based embedders
/// (BGE, Arctic) must normalize themselves before returning a vector for
/// cosine-similarity search.
///
/// Returns the input unchanged if its norm is zero (e.g. the caller fed an
/// empty string through a lower layer that still produced an all-zero vector).
func l2Normalize(_ vector: [Float]) -> [Float] {
    var sumSquares: Float = 0
    for v in vector { sumSquares += v * v }
    let norm = sqrt(sumSquares)
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
}
