import AICleanerCore
import Dispatch
import Foundation
#if os(Windows)
import CRT
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main
struct SidecarMain {
    static func main() async {
        let platform = HostPlatformAdapter.shared
        let lock: DataDirectoryLock
        do {
            lock = try DataDirectoryLock(directory: platform.userDataDirectory())
        } catch {
            let message = "aicleaner-core: failed to acquire core.lock: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(1)
        }
        let server = SidecarServer(platform: platform) { message in
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0a)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        let input = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let consumed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                if case .terminated = input.continuation.yield(line) { break }
                consumed.wait()
            }
            input.continuation.finish()
        }
        let timeout = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if await server.isIdle() {
                    input.continuation.finish()
                    break
                }
            }
        }
        for await line in input.stream {
            let keepRunning = await server.receive(line)
            if !keepRunning { input.continuation.finish() }
            consumed.signal()
            if !keepRunning { break }
        }
        timeout.cancel()
        await server.stop()
        withExtendedLifetime(lock) {
            // A host may leave stdin open after shutdown or while idle. The reader can
            // still be blocked in readLine; bypass stdio finalization after writing the reply.
            _exit(0)
        }
    }
}
