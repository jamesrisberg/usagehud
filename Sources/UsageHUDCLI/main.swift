import Foundation
import HUDKit

// `usagehud <command> [key=value ...]`: talks to UsageHUD's MacHUD control socket.
//
//   usagehud hello
//   usagehud say text="hi there"
//   usagehud panel toggle id=main
//   usagehud settings set showCount=0
//   usagehud quit

let usage = """
usage: usagehud <command> [key=value ...]
  hello | state | help | quit
  panel show|hide|toggle id=main
  panel frame id=main x= y= w= h=
  say [text=]                        change what the panel says (empty: back to the greeting)
  settings get [key=]  |  settings set key=value ...

Environment: USAGEHUD_SOCKET picks the socket name (default usagehud).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["USAGEHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "usagehud"

switch command {
case "say":
    // Shorthand for `action name=say ...`.
    arguments = ["action", "name=say"] + arguments.dropFirst()
case "settings" where arguments.count > 1 && ["get", "set"].contains(arguments[1]):
    // The sub-verb travels as `action=` so the router does not read a positional as a key.
    arguments[1] = "action=\(arguments[1])"
default:
    break
}

exit(HUDSocketClient.runCLI(path: HUDSocket.path(for: socketName), arguments: arguments, appName: "usagehud"))
