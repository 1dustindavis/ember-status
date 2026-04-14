import Foundation

public protocol BluetoothManaging: Sendable {
    var availability: BLEAvailability { get async }

    func startScanning() async throws -> [BLEDevice]
    func stopScanning() async

    func connect(to deviceID: UUID) async throws
    func disconnect(from deviceID: UUID) async

    func discoverCapabilities(for deviceID: UUID) async throws -> MugCapabilityMap
    func readValue(for characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data

    func subscribe(
        to characteristic: BLECharacteristicID,
        on deviceID: UUID
    ) async throws -> AsyncThrowingStream<Data, Error>

    var connectionEvents: AsyncStream<BLEConnectionEvent> { get }
}
