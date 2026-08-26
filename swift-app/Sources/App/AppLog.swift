// goty — see CLAUDE.md for the working principles.
import Foundation

// Referenced by the vendored Ghostty Swift sources.
struct AppLog {
    static func warning(_ msg: String) { FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!) }
    static func error(_ msg: String) { FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!) }
    static func info(_ msg: String) {}
}
