import Foundation
import Darwin

/// Separate app instances must not restore or overwrite each other's connection.
final class InstanceLock {
    private let descriptor: Int32
    init(url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GatewayError.message("无法锁定 Gateway 数据目录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw GatewayError.message("另一个 Codex Gateway 正在运行，请使用已有窗口。")
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
