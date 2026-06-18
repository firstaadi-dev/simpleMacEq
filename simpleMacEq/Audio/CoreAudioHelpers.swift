import Foundation
import CoreAudio

// ponytail: deduplicated from AudioProcessMonitor + OutputDeviceManager
enum CoreAudioHelpers {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func stringProperty(_ obj: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = result else { return nil }
        let value = cf.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}
