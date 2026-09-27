import Foundation

let args = CommandLine.arguments
for d in DDCDisplay.all() {
    if args.count > 1, let v = UInt16(args[1]) {
        print(d.name, "set volume", v, d.write(.volume, v))
    }
    if let v = d.read(.volume) { print(d.name, "volume \(v.current)/\(v.max)") } else { print(d.name, "no DDC reply") }
}
