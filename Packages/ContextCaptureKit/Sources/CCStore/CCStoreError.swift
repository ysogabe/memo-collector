import Foundation

/// CCStore が投げるエラー。
public enum CCStoreError: Error, Equatable, Sendable {
    /// insert で同じ id が既にある。
    case duplicateID(String)
    /// update / 追記系で id が無い。
    case notFound(String)
    /// 埋め込みの次元がストアの想定（既定 256）と違う。
    case dimensionMismatch(expected: Int, actual: Int)
    /// DB の行が壊れている（JSON が読めない等）。
    case corruptedRow(id: String, reason: String)
}
