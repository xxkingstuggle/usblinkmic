import Foundation
import Network
import Contracts

/// Receives complete PCM frames and pauses TCP reads until the consumer acknowledges
/// each decoded batch. At most one bounded batch is in flight, which applies
/// backpressure to the sender. Consumers should decode on this serial queue and
/// send only coalesced presentation updates to the main actor.
public typealias AudioFrameBatchHandler = @Sendable ([Data], @escaping @Sendable () -> Void) -> Void

public final class AudioReceiver: @unchecked Sendable {
 private static let maximumReceiveLength = 65_536
 private static let maximumHandshakeLength = 8_192
 private static let maximumFramesPerBatch = 64
 private static let handshakeTimeout: TimeInterval = 10
 private static let firstFrameTimeout: TimeInterval = 15

 private let queue = DispatchQueue(label: "usblinkmic.audio", qos: .userInitiated)
 private let queueKey = DispatchSpecificKey<UInt8>()

 // All mutable receiver state below is confined to queue. start/stop synchronously
 // enter it so their generation changes are ordered with Network.framework callbacks.
 private var generation: UInt64 = 0
 private var listener: NWListener?
 private var connection: NWConnection?
 private var buffer = Data()
 private var headerReceived = false
 private var active = false
 private var deliveryPending = false
 private var deferredConnectionError: String?
 private var deferredListenerFailure = false
 private var pendingTerminalError: String?
 private var handshakeTimeoutWorkItem: DispatchWorkItem?
 private var firstFrameTimeoutWorkItem: DispatchWorkItem?
 private var settings: Settings?
 private var sessionID: String?
 private var expectedToken: String?
 private var lastBindAddress: String?
 private var negotiatedAudio: AudioParameters?
 private var onHandshake: (@Sendable (AudioParameters) -> Void)?
 private var onBatch: AudioFrameBatchHandler?
 private var onError: (@Sendable (String) -> Void)?
 private var receivedBytes: UInt64 = 0
 private var receivedBatches: UInt64 = 0
 private var lastReceiveAt: UInt64 = 0
 private var maximumReceiveGap: UInt64 = 0
 private var receiveGapsOver250Ms: UInt64 = 0
 private var maximumBatchWork: UInt64 = 0
 private var maximumAcknowledgementWait: UInt64 = 0
 private var pendingBatchAt: UInt64 = 0
 private var maximumBatchPackets = 0

 public init() {
  queue.setSpecific(key: queueKey, value: 1)
 }

 /// Constant-space, cumulative timing counters. Receive gaps include scheduling
 /// delays on this queue; they do not by themselves identify a network fault.
 public var diagnostics: String {
  onReceiverQueue {
   "receivedBytes=\(receivedBytes), batches=\(receivedBatches), receiveGapMaxMs=\(maximumReceiveGap / 1_000_000), receiveGapsOver250Ms=\(receiveGapsOver250Ms), batchWorkMaxMs=\(maximumBatchWork / 1_000_000), batchAckMaxMs=\(maximumAcknowledgementWait / 1_000_000), batchPacketsMax=\(maximumBatchPackets)"
  }
 }

 public static func effectiveBindAddress(for settings: Settings) -> String {
  let trimmed = settings.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
  switch settings.transport {
  case .usb:
   return "127.0.0.1"
  case .wifi:
   return (trimmed.isEmpty || trimmed == "127.0.0.1") ? "0.0.0.0" : trimmed
  }
 }

 public var boundAddress: String? {
  onReceiverQueue { lastBindAddress }
 }

 /// Start receiving authenticated audio. `onBatch` must call its acknowledgement
 /// after that batch has been consumed or deliberately discarded. The receiver will
 /// not read again until the acknowledgement arrives.
 public func start(
  settings: Settings,
  session: String,
  expectedToken: String? = nil,
  onHandshake: (@Sendable (AudioParameters) -> Void)? = nil,
  onBatch: @escaping AudioFrameBatchHandler,
  onError: @escaping @Sendable (String) -> Void
 ) throws {
  try onReceiverQueue {
   stopOnReceiverQueue()
   guard (1...65_535).contains(settings.audioPort) else {
    throw LinkError.failure("BAD_PORT", "音频监听端口无效")
   }
   guard (1...2).contains(settings.audio.channels) else {
    throw LinkError.failure("BAD_CHANNELS", "音频声道数无效")
   }

   let tcp = NWProtocolTCP.Options()
   tcp.noDelay = true
   let parameters = NWParameters(tls: nil, tcp: tcp)
   guard let port = NWEndpoint.Port(rawValue: UInt16(settings.audioPort)) else {
    throw LinkError.failure("BAD_PORT", "音频监听端口无效")
   }
   let bindAddress = Self.effectiveBindAddress(for: settings)
   parameters.requiredLocalEndpoint = .hostPort(
    host: NWEndpoint.Host(bindAddress),
    port: port
   )
   let newListener = try NWListener(using: parameters)

   generation &+= 1
   let runGeneration = generation
   active = true
   self.settings = settings
   sessionID = session
   self.expectedToken = expectedToken
   lastBindAddress = bindAddress
   negotiatedAudio = settings.audio
   self.onHandshake = onHandshake
   self.onBatch = onBatch
   self.onError = onError
   receivedBytes = 0
   receivedBatches = 0
   lastReceiveAt = 0
   maximumReceiveGap = 0
   receiveGapsOver250Ms = 0
   maximumBatchWork = 0
   maximumAcknowledgementWait = 0
   pendingBatchAt = 0
   maximumBatchPackets = 0
   resetConnectionState()
   listener = newListener

   newListener.stateUpdateHandler = { [weak self] state in
    guard case .failed(let error) = state, let self else { return }
    self.failListener(generation: runGeneration, error: error)
   }
   newListener.newConnectionHandler = { [weak self] newConnection in
    guard let self else {
     newConnection.cancel()
     return
    }
    self.accept(newConnection, generation: runGeneration)
   }
   newListener.start(queue: queue)
  }
 }

 public func stop() {
  onReceiverQueue { stopOnReceiverQueue() }
 }

 private func stopOnReceiverQueue() {
  cancelHandshakeTimeout()
  cancelFirstFrameTimeout()
  generation &+= 1
  active = false

  let oldListener = listener
  let oldConnection = connection
  listener = nil
  connection = nil
  oldListener?.stateUpdateHandler = nil
  oldListener?.newConnectionHandler = nil
  oldConnection?.stateUpdateHandler = nil
  oldListener?.cancel()
  oldConnection?.cancel()

  settings = nil
  sessionID = nil
  expectedToken = nil
  lastBindAddress = nil
  negotiatedAudio = nil
  onHandshake = nil
  onBatch = nil
  onError = nil
  resetConnectionState()
 }

 private func accept(_ newConnection: NWConnection, generation runGeneration: UInt64) {
  guard isActive(runGeneration) else {
   newConnection.cancel()
   return
  }
  guard connection == nil else {
   newConnection.cancel()
   return
  }

  connection = newConnection
  resetConnectionState()
  armHandshakeTimeout(on: newConnection, generation: runGeneration)
  newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
   guard case .failed(let error) = state,
         let self,
         let newConnection else { return }
   self.connectionFailed(
    newConnection,
    generation: runGeneration,
    message: "INPUT_INTERRUPTED: \(error.localizedDescription)"
   )
  }
  newConnection.start(queue: queue)
  receive(newConnection, generation: runGeneration)
 }

 private func receive(_ connection: NWConnection, generation runGeneration: UInt64) {
  connection.receive(
   minimumIncompleteLength: 1,
   maximumLength: Self.maximumReceiveLength
  ) { [weak self, weak connection] data, _, done, error in
   guard let self, let connection,
         self.isCurrent(connection, generation: runGeneration) else { return }

   do {
    if let data, !data.isEmpty {
     self.buffer.append(data)
     self.receivedBytes &+= UInt64(data.count)
     if self.headerReceived {
      let now = DispatchTime.now().uptimeNanoseconds
      if self.lastReceiveAt > 0 {
       let gap = now &- self.lastReceiveAt
       self.maximumReceiveGap = max(self.maximumReceiveGap, gap)
       if gap > 250_000_000 { self.receiveGapsOver250Ms &+= 1 }
      }
      self.lastReceiveAt = now
     }
    }

    let terminalError: String?
    if let error {
     terminalError = "INPUT_INTERRUPTED: \(error.localizedDescription)"
    } else if done {
     terminalError = "[INPUT_INTERRUPTED] 手机输入已中断"
    } else {
     terminalError = nil
    }

    if !self.headerReceived {
     if let newline = self.buffer.firstIndex(of: 10) {
      guard newline <= Self.maximumHandshakeLength,
            let handshake = try JSONSerialization.jsonObject(
             with: self.buffer.prefix(upTo: newline)
            ) as? [String: Any],
            let settings = self.settings,
            let sessionID = self.sessionID,
            handshake["protocol"] as? Int == Capabilities.protocolVersion,
            handshake["session"] as? String == sessionID else {
       throw LinkError.failure("HANDSHAKE_REJECTED", "身份或音频能力不一致")
      }
      let handshakeToken = handshake["token"] as? String ?? ""
      let requiredToken = self.expectedToken ?? settings.pairingCode
      let tokenMatches = settings.transport == .wifi
       ? (requiredToken.isEmpty || handshakeToken == requiredToken)
       : (handshakeToken == requiredToken)
      guard tokenMatches,
            let rate = handshake["sampleRate"] as? Int,
            let channels = handshake["channels"] as? Int,
            let formatRaw = handshake["format"] as? String,
            let format = PCMFormat(rawValue: formatRaw),
            let sourceRaw = handshake["source"] as? String,
            let source = RecordingSource(rawValue: sourceRaw),
            Capabilities.sampleRates.contains(rate),
            Capabilities.channels.contains(channels) else {
       throw LinkError.failure("HANDSHAKE_REJECTED", "身份或音频能力不一致")
      }
      if settings.transport == .usb {
       guard rate == settings.audio.sampleRate,
             channels == settings.audio.channels,
             format == settings.audio.format,
             source == settings.audio.source else {
        throw LinkError.failure("HANDSHAKE_REJECTED", "身份或音频能力不一致")
       }
      }
      var clientAudio = AudioParameters()
      clientAudio.sampleRate = rate
      clientAudio.channels = channels
      clientAudio.format = format
      clientAudio.source = source
      self.negotiatedAudio = clientAudio
      self.onHandshake?(clientAudio)

      self.buffer = Data(self.buffer.suffix(from: self.buffer.index(after: newline)))
      self.headerReceived = true
      self.cancelHandshakeTimeout()
      self.armFirstFrameTimeout(on: connection, generation: runGeneration)
      self.sendHandshakeAcceptance(on: connection, generation: runGeneration)
     } else if self.buffer.count > Self.maximumHandshakeLength {
      throw LinkError.failure("HANDSHAKE_TOO_LARGE", "握手超长")
     }
    }

    if self.headerReceived {
     if let terminalError {
      self.pendingTerminalError = terminalError
     }
     if try self.deliverBufferedBatch(on: connection, generation: runGeneration) {
      return
     }
    }

    if let terminalError {
     self.connectionFailed(connection, generation: runGeneration, message: terminalError)
     return
    }
    self.receive(connection, generation: runGeneration)
   } catch {
    self.connectionFailed(
     connection,
     generation: runGeneration,
     message: error.localizedDescription
    )
   }
  }
 }

 private func armHandshakeTimeout(on connection: NWConnection, generation runGeneration: UInt64) {
  cancelHandshakeTimeout()
  let workItem = DispatchWorkItem { [weak self, weak connection] in
   guard let self, let connection,
         self.isCurrent(connection, generation: runGeneration),
         !self.headerReceived else { return }
   self.connectionFailed(
    connection,
    generation: runGeneration,
    message: "HANDSHAKE_TIMEOUT: 连接后10秒内未收到有效握手"
   )
  }
  handshakeTimeoutWorkItem = workItem
  queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: workItem)
 }

 private func armFirstFrameTimeout(on connection: NWConnection, generation runGeneration: UInt64) {
  cancelFirstFrameTimeout()
  let workItem = DispatchWorkItem { [weak self, weak connection] in
   guard let self, let connection,
         self.isCurrent(connection, generation: runGeneration),
         self.headerReceived else { return }
   self.connectionFailed(
    connection,
    generation: runGeneration,
    message: "FIRST_FRAME_TIMEOUT: 握手后15秒内未收到有效PCM帧"
   )
  }
  firstFrameTimeoutWorkItem = workItem
  queue.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: workItem)
 }

 private func cancelHandshakeTimeout() {
  handshakeTimeoutWorkItem?.cancel()
  handshakeTimeoutWorkItem = nil
 }

 private func cancelFirstFrameTimeout() {
  firstFrameTimeoutWorkItem?.cancel()
  firstFrameTimeoutWorkItem = nil
 }

 /// Extracts at most one bounded batch. Unconsumed bytes stay in `buffer` and are
 /// drained after the current batch is acknowledged, before another TCP read starts.
 private func deliverBufferedBatch(on connection: NWConnection, generation runGeneration: UInt64) throws -> Bool {
  guard isCurrent(connection, generation: runGeneration), headerReceived else { return false }
  guard let settings, let batchHandler = onBatch else {
   throw LinkError.failure("RECEIVER_STOPPED", "音频接收器已停止")
  }

  let activeAudio = negotiatedAudio ?? settings.audio
  let bytesPerSample = activeAudio.format == .i16 ? 2 : 4
  let bytesPerFrame = bytesPerSample * activeAudio.channels
  guard bytesPerFrame > 0 else {
   throw LinkError.failure("BAD_FORMAT", "每帧字节数无效")
  }

  var frames = [Data]()
  frames.reserveCapacity(Self.maximumFramesPerBatch)
  var consumedBytes = 0
  while frames.count < Self.maximumFramesPerBatch, buffer.count - consumedBytes >= 4 {
   let headerStart = buffer.index(buffer.startIndex, offsetBy: consumedBytes)
   let length = (0..<4).reduce(0) { partial, offset in
    (partial << 8) | Int(buffer[buffer.index(headerStart, offsetBy: offset)])
   }
   guard length > 0,
         length <= Capabilities.maxFrameBytes,
         length % bytesPerFrame == 0 else {
    throw LinkError.failure("BAD_FRAME", "帧长度无效")
   }
   guard buffer.count - consumedBytes >= length + 4 else { break }

   let payloadStart = buffer.index(headerStart, offsetBy: 4)
   let payloadEnd = buffer.index(payloadStart, offsetBy: length)
   frames.append(Data(buffer[payloadStart..<payloadEnd]))
   consumedBytes += length + 4
  }

  if consumedBytes > 0 {
   buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: consumedBytes))
  }
  guard !frames.isEmpty else { return false }

  cancelFirstFrameTimeout()
  deliveryPending = true
  receivedBatches &+= 1
  maximumBatchPackets = max(maximumBatchPackets, frames.count)
  let started = DispatchTime.now().uptimeNanoseconds
  pendingBatchAt = started
  let acknowledgement = Acknowledgement { [weak self, weak connection] in
   guard let self, let connection else { return }
   self.queue.async { [weak self, weak connection] in
    guard let self, let connection else { return }
    self.acknowledgeBatch(on: connection, generation: runGeneration)
   }
  }
  batchHandler(frames, { acknowledgement.fire() })
  maximumBatchWork = max(maximumBatchWork, DispatchTime.now().uptimeNanoseconds &- started)
  return true
 }

 private func sendHandshakeAcceptance(on connection: NWConnection, generation runGeneration: UInt64) {
  connection.send(
   content: Data("{\"accepted\":true}\n".utf8),
   completion: .contentProcessed { [weak self, weak connection] error in
    guard let error, let self, let connection else { return }
    self.queue.async { [weak self, weak connection] in
     guard let self, let connection else { return }
     self.connectionFailed(
      connection,
      generation: runGeneration,
      message: "HANDSHAKE_ACK_FAILED: \(error.localizedDescription)"
     )
    }
   }
  )
 }

 private func acknowledgeBatch(
  on connection: NWConnection,
  generation runGeneration: UInt64
 ) {
  guard isCurrent(connection, generation: runGeneration), deliveryPending else { return }
  if pendingBatchAt > 0 {
   maximumAcknowledgementWait = max(maximumAcknowledgementWait, DispatchTime.now().uptimeNanoseconds &- pendingBatchAt)
   pendingBatchAt = 0
  }
  deliveryPending = false

  do {
   if try deliverBufferedBatch(on: connection, generation: runGeneration) { return }
  } catch {
   finishConnection(connection, generation: runGeneration, message: error.localizedDescription)
   return
  }

  if let deferredConnectionError {
   self.deferredConnectionError = nil
   if deferredListenerFailure {
    deferredListenerFailure = false
    finishRun(generation: runGeneration, message: deferredConnectionError)
   } else {
    finishConnection(connection, generation: runGeneration, message: deferredConnectionError)
   }
   return
  }
  if let pendingTerminalError {
   self.pendingTerminalError = nil
   finishConnection(connection, generation: runGeneration, message: pendingTerminalError)
   return
  }
  receive(connection, generation: runGeneration)
 }

 private func connectionFailed(
  _ connection: NWConnection,
  generation runGeneration: UInt64,
  message: String
 ) {
  guard isCurrent(connection, generation: runGeneration) else { return }
  if deliveryPending {
   if deferredConnectionError == nil {
    deferredConnectionError = message
   }
   connection.cancel()
   return
  }
  finishConnection(connection, generation: runGeneration, message: message)
 }

 private func finishConnection(
  _ connection: NWConnection,
  generation runGeneration: UInt64,
  message: String
 ) {
  guard isCurrent(connection, generation: runGeneration) else { return }
  self.connection = nil
  connection.stateUpdateHandler = nil
  connection.cancel()
  cancelHandshakeTimeout()
  cancelFirstFrameTimeout()
  resetConnectionState()
  onError?(message)
 }

 private func failListener(generation runGeneration: UInt64, error: NWError) {
  guard isActive(runGeneration) else { return }
  let message = "LISTEN_FAILED: \(error.localizedDescription)"
  let failedListener = listener
  listener = nil
  failedListener?.stateUpdateHandler = nil
  failedListener?.newConnectionHandler = nil
  failedListener?.cancel()

  if deliveryPending {
   if deferredConnectionError == nil {
    deferredConnectionError = message
   }
   deferredListenerFailure = true
   return
  }
  finishRun(generation: runGeneration, message: message)
 }

 private func finishRun(generation runGeneration: UInt64, message: String) {
  guard isActive(runGeneration) else { return }
  active = false

  let failedConnection = connection
  connection = nil
  failedConnection?.stateUpdateHandler = nil
  failedConnection?.cancel()

  let errorHandler = onError
  settings = nil
  sessionID = nil
  expectedToken = nil
  lastBindAddress = nil
  negotiatedAudio = nil
  onHandshake = nil
  onBatch = nil
  onError = nil
  cancelHandshakeTimeout()
  cancelFirstFrameTimeout()
  resetConnectionState()
  errorHandler?(message)
 }

 private func isActive(_ runGeneration: UInt64) -> Bool {
  active && generation == runGeneration
 }

 private func isCurrent(_ connection: NWConnection, generation runGeneration: UInt64) -> Bool {
  isActive(runGeneration) && self.connection === connection
 }

 private func resetConnectionState() {
  buffer.removeAll(keepingCapacity: false)
  headerReceived = false
  deliveryPending = false
  pendingBatchAt = 0
  lastReceiveAt = 0
  deferredConnectionError = nil
  deferredListenerFailure = false
  pendingTerminalError = nil
 }

 private func onReceiverQueue<T>(_ body: () throws -> T) rethrows -> T {
  if DispatchQueue.getSpecific(key: queueKey) != nil {
   return try body()
  }
  return try queue.sync(execute: body)
 }
}

private final class Acknowledgement: @unchecked Sendable {
 private let lock = NSLock()
 private var hasFired = false
 private let action: @Sendable () -> Void

 init(action: @escaping @Sendable () -> Void) {
  self.action = action
 }

 func fire() {
  lock.lock()
  let shouldRun = !hasFired
  hasFired = true
  lock.unlock()
  if shouldRun {
   action()
  }
 }
}
