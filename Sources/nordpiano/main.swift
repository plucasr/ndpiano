import Foundation
import NordPianoCore
import NordPianoEngine

setbuf(stdout, nil) // print() through a pipe is block-buffered otherwise

// Local-only Nord Piano (.npno) player:
//   nordpiano info <file.npno>   — print zones, strokes, loops
//   nordpiano play <file.npno>   — MIDI in (CoreMIDI), audio out (CoreAudio); Ctrl-C to quit
let args = CommandLine.arguments
guard args.count > 2 else {
    fputs("usage: nordpiano info|play <file.npno>\n", stderr)
    exit(2)
}
let url = URL(fileURLWithPath: args[2])
guard let data = try? Data(contentsOf: url) else {
    fputs("can't read \(args[2])\n", stderr)
    exit(1)
}
let bytes = [UInt8](data)

switch args[1] {
case "info":
    let zones = readNspZones(bytes)
    print("zones: \(zones.count)")
    for z in zones { print("  root \(z.rootNote)  keys \(z.lowNote)...\(z.highNote)") }
    do {
        let dir = try readNspDirectory(bytes)
        print("directory: version \(dir.version), \(dir.channels)ch, blockWords \(dir.blockWords), \(dir.strokes.count) strokes, \(nspZoneCount(dir)) key zones")
        for s in dir.strokes {
            print("  stroke \(s.index): zone \(s.zone) floor \(s.velocityFrom) frames \(s.frames) blocks \(s.blocks)" +
                  (s.loop.map { " loop \($0.start)+\($0.length)" } ?? "") + (s.release ? " release" : ""))
        }
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
case "play":
    do {
        let player = try PianoPlayer(bytes: bytes)
        try player.start()
        RunLoop.current.run() // Ctrl-C to quit
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
default:
    fputs("usage: nordpiano info|play <file.npno>\n", stderr)
    exit(2)
}
