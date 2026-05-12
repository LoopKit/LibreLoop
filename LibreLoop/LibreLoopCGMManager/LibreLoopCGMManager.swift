import Foundation
import HealthKit
import LoopKit

public final class LibreLoopCGMManager: CGMManager {
    public static let pluginIdentifier = "LibreLoopCGMManager"
    public static let localizedTitle = "FreeStyle Libre 3"
    public static let healthKitStorageDelay: TimeInterval = 0

    public var localizedTitle: String { Self.localizedTitle }

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: LibreLoopCGMManagerState
    public var rawState: CGMManager.RawStateValue { state.rawValue }

    public let isOnboarded = true

    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }
    public var glucoseDisplay: GlucoseDisplayable? { nil }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(hasValidSensorSession: state.sensorSerial != nil,
                         lastCommunicationDate: state.latestReadingTimestamp,
                         device: device)
    }

    public var device: HKDevice? {
        HKDevice(name: "FreeStyle Libre 3",
                 manufacturer: "Abbott",
                 model: "Libre 3",
                 hardwareVersion: nil,
                 firmwareVersion: nil,
                 softwareVersion: nil,
                 localIdentifier: state.sensorSerial,
                 udiDeviceIdentifier: nil)
    }

    public var debugDescription: String {
        """
        ## LibreLoopCGMManager
        * sensorSerial: \(state.sensorSerial ?? "nil")
        * activatedAt: \(String(describing: state.activatedAt))
        * latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))
        """
    }

    public init() {
        self.state = LibreLoopCGMManagerState()
    }

    public required convenience init?(rawState: CGMManager.RawStateValue) {
        self.init()
        if let parsed = LibreLoopCGMManagerState(rawValue: rawState) {
            self.state = parsed
        }
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        completion(.noData)
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()

    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func delete(completion: @escaping () -> Void) {
        completion()
    }
}
