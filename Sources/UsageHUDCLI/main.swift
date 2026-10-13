import Foundation
import HUDKit

// `usagehud <command> [key=value ...]`: talks to UsageHUD's MacHUD control socket.
//
//   usagehud hello
//   usagehud usage              # every provider's status, readings and their ages
//   usagehud refresh            # read both now (same as `usagehud action refresh`)
//   usagehud refresh claude     # one provider
//   usagehud panel toggle id=main
//   usagehud settings set pollMinutes=10
//   usagehud quit

let usage = """
usage: usagehud <command> [key=value ...]
  hello | state | help | quit
  usage                              each provider's status, last reading, its age and windows
  refresh [claude|codex]             read now (both by default), past any backoff
  panel show|hide|toggle id=main
  panel frame id=main x= y= w= h=
  action <verb> [k=v ...]            the long form (action refresh provider=codex)
  settings get [key=]  |  settings set key=value ...
  widget list|create|update|remove|edit|reveal ...

Environment: USAGEHUD_SOCKET picks the socket name (default usagehud).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["USAGEHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "usagehud"

switch command {
case "usage":
    // Shorthand for `action name=usage`.
    arguments = ["action", "name=usage"] + arguments.dropFirst()
case "refresh":
    // `refresh codex` is `action name=refresh provider=codex`; `refresh provider=codex` works too.
    let rest = arguments.dropFirst().map { $0.contains("=") ? $0 : "provider=\($0)" }
    arguments = ["action", "name=refresh"] + rest
case "settings" where arguments.count > 1 && ["get", "set"].contains(arguments[1]):
    // The sub-verb travels as `action=` so the router does not read a positional as a key.
    arguments[1] = "action=\(arguments[1])"
default:
    break
}

exit(HUDSocketClient.runCLI(path: HUDSocket.path(for: socketName), arguments: arguments, appName: "usagehud"))
