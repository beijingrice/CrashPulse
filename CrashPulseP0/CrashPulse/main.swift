import Darwin

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "--capture":
    exit(DiagnosticCapture.run(Array(arguments.dropFirst())))
case let command? where command == "--monitor" || command == "--history":
    exit(HistoryCommand.run(command, arguments: Array(arguments.dropFirst())))
default:
    CrashPulseApp.main()
}
