import Foundation

extension StringProtocol {
    var isNewline: Bool { return self == "\n" || self == "\r\n" }
}
