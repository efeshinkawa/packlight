import Foundation
import IOKit.ps

struct PowerState: Equatable {
    var onAC: Bool
    var percent: Int

    static func current() -> PowerState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        var percent = 100
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let cur = d[kIOPSCurrentCapacityKey] as? Int,
               let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = cur * 100 / max
            }
        }
        return PowerState(onAC: type == kIOPMACPowerKey, percent: percent)
    }
}

/// Calls `onChange` on the main thread whenever the power source info changes.
final class PowerMonitor {
    private let onChange: (PowerState) -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping (PowerState) -> Void) {
        self.onChange = onChange
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.onChange(PowerState.current())
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
