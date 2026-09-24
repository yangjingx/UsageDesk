import AppKit

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--refresh"] { exit(runRefreshCommand()) }
if !args.isEmpty { exit(runUpdateCommand(args)) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.run()
}
