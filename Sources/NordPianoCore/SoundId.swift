import Foundation

/// The 32-bit id a program uses to name the piano or sample it plays:
/// MurmurHash2 (m = 0x5bd1e995, r = 24, seed 0) of the sound's library name,
/// reading 4-byte blocks big-endian; 0 is stored as 1 (0 means "none").
/// Port of OpenNord's `clavia/sound-id.ts` (AGPL-3.0) — the algorithm the
/// Stage 2/3 firmware uses when upgrading old programs.
public func soundId(_ libraryName: String) -> UInt32 {
    let data = [UInt8](libraryName.utf8)
    let m: UInt32 = 0x5bd1e995
    var h = UInt32(truncatingIfNeeded: data.count)
    var i = 0
    while data.count - i >= 4 {
        var k = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16
            | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
        k = k &* m
        k = (k ^ (k >> 24))
        k = k &* m
        h = (h &* m) ^ k
        i += 4
    }
    let rest = data.count - i
    if rest == 3 { h = h ^ (UInt32(data[i + 2]) << 16) }
    if rest >= 2 { h = h ^ (UInt32(data[i + 1]) << 8) }
    if rest >= 1 { h = (h ^ UInt32(data[i])) &* m }
    h = h ^ (h >> 13)
    h = h &* m
    h = h ^ (h >> 15)
    return h == 0 ? 1 : h
}

/// A sound file's library name (what the hash covers): the file name without
/// its extension; a piano's underscores read as spaces, a sample's kept as-is.
public func soundLibraryName(ofFile filename: String) -> String {
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension.lowercased()
    return ext == "npno" ? base.replacingOccurrences(of: "_", with: " ") : base
}

/// The "no sound referenced" sentinel the Stage 4 writes for an empty synth
/// slot (not a valid MurmurHash2 output of any name).
public let emptySoundHash = 0xe53db350
