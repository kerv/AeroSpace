import Common

struct DebugLogMarkerCommand: Command {
    let args: DebugLogMarkerCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        AeroLog.marker(args._label ?? "")
        io.out("Marker written to \(AeroLog.logFileURL.path)")
        return .succ
    }
}
