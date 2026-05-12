import Foundation

extension LibreLoopCGMManager {
    /// Persists a successful pairing outcome:
    ///   - sensor metadata is folded into `state` (rawState-persisted)
    ///   - session crypto keys (kEnc, ivEnc) go into the Keychain keyed by serial
    public func applyPairingResult(_ result: LibreLoopPairingService.Result) throws {
        try LibreLoopKeychain.save(
            LibreLoopKeychain.SessionKeys(kEnc: result.kEnc, ivEnc: result.ivEnc),
            forSensorSerial: result.sensorSerial
        )

        var newState = state
        newState.receiverID = withUnsafeBytes(of: result.receiverID.littleEndian) { Data($0) }
        newState.sensorSerial = result.sensorSerial
        newState.bleAddress = result.bleAddress
        newState.activatedAt = result.activatedAt
        setState(newState)
    }

    func setState(_ newState: LibreLoopCGMManagerState) {
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
    }
}
