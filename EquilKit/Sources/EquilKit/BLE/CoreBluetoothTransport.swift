import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth

/// `EquilTransport` 的 Core Bluetooth 实现。
///
/// 对照 AndroidAPS `EquilBLE.kt` 的平台层。差异点：
/// - **设备标识**：iOS 无 MAC，用 `CBPeripheral.identifier`（每台手机稳定，跨手机不同），
///   首配靠广播名 `Equil - <SN>` 匹配。
/// - **连接参数**：iOS 无 `requestConnectionPriority`，由系统协商，不做干预。
/// - **MTU**：iOS 无 `requestMtu`，用 `maximumWriteValueLength` 反推上报。
/// - **CCC**：iOS 只能通过 `setNotifyValue` 订阅，该调用会写 2902 描述符。
///   若泵确实以"是否写 CCC"区分客户端画像，则 iOS 无法在不写 CCC 的前提下收通知——
///   这是本移植最大的未决点，需真机验证（见 `docs/09-iOS BLE 移植说明.md`）。
public final class CoreBluetoothTransport: NSObject, EquilTransport, CBCentralManagerDelegate, CBPeripheralDelegate {

    public weak var delegate: EquilTransportDelegate?

    public var targetIdentifier: UUID?
    public var targetNamePrefix: String?
    public var skipCccSubscription = false
    public var writeWithResponse = false

    /// 首次匹配/连接成功时回报外设标识，供驱动层持久化（后续可直连免扫描）。
    public var onPeripheralIdentifier: ((UUID) -> Void)?

    public var isConnected: Bool {
        peripheral?.state == .connected
    }

    private let serviceUUID = CBUUID(string: EquilGatt.serviceRadio)
    private let characteristicUUID = CBUUID(string: EquilGatt.characteristicNotify)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var shouldScan = false

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - EquilTransport

    public func startScan() {
        shouldScan = true
        guard central.state == .poweredOn else {
            EquilLog.warn("startScan: bluetooth not powered on (\(central.state.rawValue))")
            return
        }
        EquilLog.debug("startScan (service \(EquilGatt.serviceRadio))")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    public func stopScan() {
        shouldScan = false
        guard central.state == .poweredOn else { return }
        central.stopScan()
    }

    public func connect() {
        if let known = targetIdentifier, let existing = central.retrievePeripherals(withIdentifiers: [known]).first {
            EquilLog.info("connect: direct connect to known peripheral")
            connectPeripheral(existing)
            return
        }
        // 无已知标识则退回扫描路径。
        startScan()
    }

    public func disconnect() {
        if let peripheral = peripheral {
            EquilLog.debug("disconnect: cancel peripheral connection")
            central.cancelPeripheralConnection(peripheral)
        }
    }

    public func write(_ bytes: [UInt8]) {
        guard let peripheral = peripheral, let characteristic = writeCharacteristic else {
            EquilLog.debug("write: no peripheral/characteristic")
            return
        }
        let data = Data(bytes)
        let type: CBCharacteristicWriteType = writeWithResponse ? .withResponse : .withoutResponse
        EquilLog.debug("write \(bytes.count)B type=\(writeWithResponse ? "withResponse" : "withoutResponse")")
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    public func setNotify(_ enabled: Bool) {
        guard let peripheral = peripheral, let characteristic = notifyCharacteristic else {
            EquilLog.debug("setNotify: no notify characteristic")
            return
        }
        EquilLog.debug("setNotify \(enabled)")
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    // MARK: - 内部

    private func connectPeripheral(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        onPeripheralIdentifier?(target.identifier)
        central.connect(target, options: nil)
    }

    private func matches(_ peripheral: CBPeripheral) -> Bool {
        if let identifier = targetIdentifier {
            return peripheral.identifier == identifier
        }
        if let prefix = targetNamePrefix, let name = peripheral.name {
            return name.hasPrefix(prefix)
        }
        // 未指定目标时，任何广播名以 Equil 开头的设备都视作候选。
        return peripheral.name?.hasPrefix(EquilGatt.advertisedNamePrefix) == true
    }

    private func advertisementBytes(_ advertisementData: [String: Any]) -> [UInt8] {
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            return [UInt8](manufacturer)
        }
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let first = serviceData.values.first {
            return [UInt8](first)
        }
        return []
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        EquilLog.debug("central state=\(central.state.rawValue)")
        if central.state == .poweredOn, shouldScan {
            startScan()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matches(peripheral) else { return }
        EquilLog.info("discovered pump \(peripheral.name ?? "?") rssi=\(RSSI)")
        onPeripheralIdentifier?(peripheral.identifier)
        stopScan()
        let adv = advertisementBytes(advertisementData)
        delegate?.transportDidDiscover(advertisement: adv, rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        EquilLog.info("connected to pump, discovering services")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
        delegate?.transportDidConnect()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        EquilLog.warn("didFailToConnect: \(error?.localizedDescription ?? "unknown")")
        delegate?.transportDidDisconnect(error: .connectFailed)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        EquilLog.info("didDisconnectPeripheral: \(error?.localizedDescription ?? "clean")")
        self.peripheral = nil
        self.notifyCharacteristic = nil
        self.writeCharacteristic = nil
        delegate?.transportDidDisconnect(error: error == nil ? nil : .remoteTerminated)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            delegate?.transportDidDiscoverServices(hasTargetService: false)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            EquilLog.warn("target service not found")
            delegate?.transportDidDiscoverServices(hasTargetService: false)
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            delegate?.transportDidDiscoverServices(hasTargetService: false)
            return
        }
        notifyCharacteristic = characteristic
        writeCharacteristic = characteristic
        // iOS 无 requestMtu，用最大写入长度反推（+3 为 ATT 头）。
        delegate?.transportDidUpdateMtu(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)
        delegate?.transportDidDiscoverServices(hasTargetService: true)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            EquilLog.warn("notify state error: \(error.localizedDescription)")
            delegate?.transportDidDisconnect(error: .notifySubscriptionFailed)
            return
        }
        if characteristic.isNotifying {
            delegate?.transportIsReady()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        delegate?.transportDidReceive([UInt8](value))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        delegate?.transportDidWrite()
    }
}

#endif