import Foundation
import Darwin

/// The app bundle carries libzstd; development builds can use Homebrew's copy.
/// This preserves Codex's existing request-compression setting.
enum RequestCompression {
    static func decode(_ data: Data, encoding: String?) throws -> Data {
        guard let encoding, !encoding.isEmpty, encoding != "identity" else { return data }
        guard encoding == "zstd" else { throw GatewayError.message("不支持的请求压缩：\(encoding)") }
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libzstd.1.dylib").path,
                     "/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib"]
        var handle: UnsafeMutableRawPointer?
        for path in paths where handle == nil { handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) }
        guard let library = handle else {
            throw GatewayError.message("缺少 zstd 解压库，请使用完整应用包。")
        }
        defer { dlclose(library) }
        typealias Bound = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
        typealias Decode = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        typealias IsError = @convention(c) (Int) -> UInt32
        guard let boundSymbol = dlsym(library, "ZSTD_decompressBound"),
              let decodeSymbol = dlsym(library, "ZSTD_decompress"),
              let errorSymbol = dlsym(library, "ZSTD_isError") else {
            throw GatewayError.message("zstd 库不兼容")
        }
        let bound = unsafeBitCast(boundSymbol, to: Bound.self)
        let decode = unsafeBitCast(decodeSymbol, to: Decode.self)
        let isError = unsafeBitCast(errorSymbol, to: IsError.self)
        let size = data.withUnsafeBytes { bound($0.baseAddress, $0.count) }
        guard size <= 64 * 1024 * 1024 else { throw GatewayError.message("压缩请求超过 64 MiB") }
        var output = Data(count: Int(size))
        let result = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in decode(destination.baseAddress, destination.count, source.baseAddress, source.count) }
        }
        guard isError(result) == 0 else { throw GatewayError.message("无法解压请求") }
        output.count = result
        return output
    }
}
