import Foundation
import Network
import Contracts
import Support

public enum WifiListenerState: Equatable, Sendable {
 case stopped, starting
 case ready(port: UInt16, advertised: Bool)
 case waiting(String)
 case failed(String)
}

/// Accepts control connections for `WifiControlService` and (optionally) publishes the Bonjour
/// service `_usblinkmic._tcp`. The TXT record carries only non-secret identity metadata.
public final class WifiControlListener: @unchecked Sendable {
 public struct Configuration: Sendable {
  public var macID: String
  public var macName: String
  /// false for isolated tests: no Bonjour registration is ever made.
  public var advertise: Bool
  /// true for isolated tests: listen on the loopback interface only.
  public var loopbackOnly: Bool
  public init(macID: String, macName: String, advertise: Bool = true, loopbackOnly: Bool = false) {
   self.macID = macID; self.macName = macName; self.advertise = advertise; self.loopbackOnly = loopbackOnly
  }
 }

 static let maximumLineBytes = 4096
 static let maximumConnections = 8

 private let queue = DispatchQueue(label: "usblinkmic.wifi-control")
 private let configuration: Configuration
 private let service: WifiControlService
 private let onState: @Sendable (WifiListenerState) -> Void
 private var listener: NWListener?
 private var generation: UInt64 = 0
 private var activeConnections: [UUID: WifiControlConnection] = [:]

 public init(service: WifiControlService, configuration: Configuration, onState: @escaping @Sendable (WifiListenerState) -> Void) {
  self.service = service; self.configuration = configuration; self.onState = onState
 }

 public func start() throws {
  try queue.sync {
   stopLocked()
   let parameters = NWParameters.tcp
   if configuration.loopbackOnly { parameters.requiredInterfaceType = .loopback }
   let created = try NWListener(using: parameters)
   if configuration.advertise {
    let txt = NWTXTRecord([
     "v": String(Capabilities.protocolVersion), "w": String(Capabilities.wifiRevision),
     "rev": String(Capabilities.runtimeRevision), "id": configuration.macID,
     "name": String(configuration.macName.prefix(40))
    ])
    created.service = NWListener.Service(name: "USBLinkMic-\(configuration.macID.prefix(8))", type: Capabilities.bonjourServiceType, txtRecord: txt)
   }
   generation &+= 1
   let current = generation
   listener = created
   onState(.starting)
   created.stateUpdateHandler = { [weak self] state in
    guard let self else { return }
    self.queue.async {
     guard self.generation == current else { return }
     switch state {
     case .ready: self.onState(.ready(port: created.port?.rawValue ?? 0, advertised: self.configuration.advertise))
     case .waiting(let error): self.onState(.waiting(error.localizedDescription))
     case .failed(let error): self.onState(.failed(error.localizedDescription))
     default: break
     }
    }
   }
   created.newConnectionHandler = { [weak self] connection in
    guard let self else { connection.cancel(); return }
    self.queue.async { [weak self] in
     guard let self, self.generation == current, self.activeConnections.count < Self.maximumConnections else {
      connection.cancel()
      return
     }
     let connectionKey = UUID()
     let wrapper = WifiControlConnection(connection: connection, service: self.service) { [weak self] in
      self?.queue.async {
       self?.activeConnections.removeValue(forKey: connectionKey)
      }
     }
     self.activeConnections[connectionKey] = wrapper
     wrapper.start()
    }
   }
   created.start(queue: queue)
  }
 }

 public var port: UInt16? { queue.sync { listener?.port?.rawValue } }
 public var activeConnectionCount: Int { queue.sync { activeConnections.count } }

 public func stop() { queue.sync { stopLocked(); onState(.stopped) } }

 private func stopLocked() {
  generation &+= 1
  listener?.stateUpdateHandler = nil
  listener?.newConnectionHandler = nil
  listener?.cancel()
  listener = nil
  let staleConnections = Array(activeConnections.values)
  activeConnections.removeAll()
  for connection in staleConnections {
   connection.cancelImmediately()
  }
 }
}

/// One accepted TCP connection: newline-delimited JSON, at most 4 KiB per line, processed in
/// order (the next read is issued only after the service finished the previous message).
final class WifiControlConnection: WifiPeerConnection, @unchecked Sendable {
 private let connection: NWConnection
 private let service: WifiControlService
 private let queue = DispatchQueue(label: "usblinkmic.wifi-control.connection")
 private let finished: @Sendable () -> Void
 private var buffer = Data()
 private var serviceID: UUID?
 private var closedNotified = false

 init(connection: NWConnection, service: WifiControlService, finished: @escaping @Sendable () -> Void) {
  self.connection = connection; self.service = service; self.finished = finished
 }

 func start() {
  queue.async {
   guard !self.closedNotified else { return }
   self.connection.stateUpdateHandler = { [weak self] state in
    switch state {
    case .failed, .cancelled:
     self?.handleClosedOnQueue()
    default:
     break
    }
   }
   self.connection.start(queue: self.queue)
   Task { @MainActor [weak self] in
    guard let self else { return }
    let canOpen = self.queue.sync { !self.closedNotified }
    guard canOpen else { return }
    let openedID = self.service.connectionOpened(self)
    let registered = self.queue.sync { () -> Bool in
     guard !self.closedNotified else { return false }
     self.serviceID = openedID
     self.readOnQueue()
     return true
    }
    if !registered {
     self.service.connectionClosed(openedID)
    }
   }
  }
 }

 func send(_ object: [String: Any]) {
  guard JSONSerialization.isValidJSONObject(object), var data = try? JSONSerialization.data(withJSONObject: object) else { return }
  data.append(10)
  queue.async {
   guard !self.closedNotified else { return }
   self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
    if error != nil { self?.close() }
   })
  }
 }

 func close() {
  queue.async {
   guard !self.closedNotified else { return }
   // Let a final error reply flush before the socket goes away.
   self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
    self?.connection.cancel()
   })
   self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
    self?.connection.cancel()
    self?.handleClosedOnQueue()
   }
  }
 }

 func cancelImmediately() {
  queue.async {
   self.connection.stateUpdateHandler = nil
   self.connection.cancel()
   self.handleClosedOnQueue()
  }
 }

 private func handleClosedOnQueue() {
  guard !closedNotified else { return }
  closedNotified = true
  let id = serviceID
  serviceID = nil
  finished()
  if let id {
   Task { @MainActor [service] in
    service.connectionClosed(id)
   }
  }
 }

 private func readOnQueue() {
  guard !closedNotified else { return }
  connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, isComplete, error in
   guard let self, !self.closedNotified else { return }
   if let data { self.buffer.append(data) }
   var messages: [[String: Any]] = []
   while let newline = self.buffer.firstIndex(of: 10) {
    let line = self.buffer.prefix(upTo: newline)
    self.buffer = Data(self.buffer.suffix(from: self.buffer.index(after: newline)))
    guard line.count <= WifiControlListener.maximumLineBytes,
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
     self.connection.cancel()
     self.handleClosedOnQueue()
     return
    }
    messages.append(object)
   }
   if self.buffer.count > WifiControlListener.maximumLineBytes {
    self.connection.cancel()
    self.handleClosedOnQueue()
    return
   }
   if error != nil || (isComplete && messages.isEmpty) {
    self.connection.cancel()
    self.handleClosedOnQueue()
    return
   }
   guard let id = self.serviceID else {
    self.connection.cancel()
    self.handleClosedOnQueue()
    return
   }
   let ended = isComplete
   Task { @MainActor in
    for message in messages { await self.service.receive(message, on: id) }
    self.queue.async {
     guard !self.closedNotified else { return }
     if ended {
      self.connection.cancel()
      self.handleClosedOnQueue()
     } else {
      self.readOnQueue()
     }
    }
   }
  }
 }
}
