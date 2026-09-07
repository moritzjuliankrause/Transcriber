import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while a recording runs.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var active = false

    init(reason: String) {
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        active = status == kIOReturnSuccess
    }

    deinit {
        if active { IOPMAssertionRelease(id) }
    }
}
