import Darwin

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "--capture":
    exit(DiagnosticCapture.run(Array(arguments.dropFirst())))
case let command? where command == "--monitor" || command == "--history":
    exit(HistoryCommand.run(command, arguments: Array(arguments.dropFirst())))
#if DEBUG
case "--render-ui":
    exit(MainActor.assumeIsolated { UIPreviewRenderer.run(Array(arguments.dropFirst())) })
#endif
default:
    CrashPulseApp.main()
}
