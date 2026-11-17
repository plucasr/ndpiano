import Foundation

public enum SoundFontError: Error {
    case notASoundFont
}

/// SF2/DLS container check: the file must be a RIFF with form type "sfbk"
/// (SoundFont 2) or "DLS " (Downloadable Sounds). Used for identity reads and
/// import validation — playback itself is Apple's AUSampler.
public func isSoundFont(bytes: [UInt8]) -> Bool {
    guard bytes.count >= 12,
          bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 // RIFF
    else { return false }
    let form = String(bytes: bytes[8..<12], encoding: .ascii)
    return form == "sfbk" || form == "DLS "
}
