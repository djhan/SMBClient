import Foundation
import Network

public class Connection: @unchecked Sendable {
  let host: String
  var onDisconnected: (Error) -> Void

  private let connection: NWConnection
  private let queue: DispatchQueue
  private var buffer = Data()

  private let semaphore = Semaphore(value: 1)

  public var state: NWConnection.State {
    connection.state
  }

  public init(host: String) {
    self.host = host

    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: 445)
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    queue = DispatchQueue(label: "com.kishikawakatsumi.smbclient.connection.\(host):445", qos: .userInitiated)
    onDisconnected = { _ in }
  }

  public init(host: String, port: Int) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: UInt16(port))!
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    queue = DispatchQueue(label: "com.kishikawakatsumi.smbclient.connection.\(host):\(port)", qos: .userInitiated)
    onDisconnected = { _ in }
  }

  public func connect() async throws {
    // withTaskCancellationHandler: 취소 시 onCancel → box.resume + connection.cancel().
    // stateUpdateHandler도 box.resume을 통해 one-shot으로 resume하므로
    // onCancel과의 경쟁 조건(이중 resume)을 방지한다.
    //
    // 핵심 엣지 케이스: 태스크가 이미 취소된 상태로 withTaskCancellationHandler에 진입하면
    // onCancel이 operation보다 먼저 실행된다. 이때 box는 아직 비어 있어 no-op이 되고,
    // connection.cancel()이 먼저 호출된다. 이후 guard !Task.isCancelled에 의해
    // start()를 호출하지 않고 즉시 CancellationError로 resume해 자원 낭비를 방지한다.
    let box = ContinuationBox<Void>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation) in
        box.set(continuation)

        // 이미 취소된 채로 진입한 경우 onCancel이 먼저 실행돼 connection.cancel()이 호출됐을 수 있다.
        // 취소된 NWConnection에 start()를 호출하지 않도록 여기서 조기 종료한다.
        guard !Task.isCancelled else {
          box.resume(with: .failure(CancellationError()))
          return
        }

        connection.stateUpdateHandler = { [weak self] (state) in
          switch state {
          case .setup, .preparing:
            break
          case .waiting(let error):
            box.resume(with: .failure(error))
            self?.connection.stateUpdateHandler = nil
          case .ready:
            box.resume(with: .success(()))
            // NWConnection delivers all state updates on `queue`, so assigning
            // stateUpdateHandler here is safe: it runs on the same serial queue
            // as any future state updates.
            self?.connection.stateUpdateHandler = { [weak self] state in
              switch state {
              case .waiting(let error), .failed(let error):
                self?.onDisconnected(error)
              case .setup, .preparing, .ready, .cancelled:
                break
              @unknown default:
                break
              }
            }
          case .failed(let error):
            box.resume(with: .failure(error))
            self?.connection.stateUpdateHandler = nil
          case .cancelled:
            box.resume(with: .failure(ConnectionError.cancelled))
            self?.connection.stateUpdateHandler = nil
          @unknown default:
            break
          }
        }

        connection.start(queue: queue)
      }
    } onCancel: {
      box.resume(with: .failure(CancellationError()))
      self.connection.cancel()
    }
  }

  public func disconnect() {
    // Do not nil stateUpdateHandler before cancelling: NWConnection delivers
    // the .cancelled state update asynchronously, and clearing the handler
    // first would prevent any in-flight connect() continuation from being
    // resumed, causing a hang. The retain cycle is instead broken by
    // capturing self weakly in the handler closures.
    connection.cancel()
  }

  public func send(_ data: Data) async throws -> Data {
    await semaphore.wait()
    defer { Task { await semaphore.signal() } }

    switch connection.state {
    case .setup:
      try await connect()
    case .waiting(let error), .failed(let error):
      onDisconnected(error)
      throw error
    case .preparing, .ready:
      break
    case .cancelled:
      throw ConnectionError.cancelled
    @unknown default:
      throw ConnectionError.unknown
    }

    let transportPacket = DirectTCPPacket(smb2Message: data)
    let content = transportPacket.encoded()

    // ContinuationBox: NWConnection이 cancel 후에도 completion을 호출하지 않는 경우,
    // withTaskCancellationHandler의 onCancel에서 continuation을 직접 resume한다.
    // 이중 resume을 방지하기 위해 lock으로 보호된 one-shot 패턴을 사용한다.
    let box = ContinuationBox<Data>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.set(continuation)

        // 이미 취소된 채로 진입한 경우 onCancel이 box 설정 전에 실행됐으므로
        // 여기서 명시적으로 resume한다. NWConnection이 이미 cancel됐을 때
        // completion을 호출하지 않는 경우에도 continuation이 반드시 완료되도록 보장한다.
        guard !Task.isCancelled else {
          box.resume(with: .failure(CancellationError()))
          return
        }

        // [weak self]: NWConnection이 이 클로저를 보유하는 동안
        // Connection → NWConnection → 클로저 → Connection 강참조 순환을 방지한다.
        connection.send(content: content, completion: .contentProcessed() { [weak self] error in
          if let error {
            box.resume(with: .failure(error))
            return
          }
          guard let self else {
            box.resume(with: .failure(ConnectionError.cancelled))
            return
          }
          self.receive { result in
            box.resume(with: result)
          }
        })
      }
    } onCancel: {
      // 태스크 취소 시 continuation을 즉시 resume한 뒤 NWConnection을 cancel한다.
      // NWConnection이 completion을 호출하더라도 box가 이중 resume을 차단한다.
      box.resume(with: .failure(CancellationError()))
      self.connection.cancel()
    }
  }

  private func receive(completion: @escaping (Result<Data, Error>) -> Void) {
    let minimumIncompleteLength = 1
    let maximumLength = 65536

    connection.receive(
      minimumIncompleteLength: minimumIncompleteLength,
      maximumLength: maximumLength)
    // [weak self]: NWConnection이 이 클로저를 보유하는 동안
    // Connection → NWConnection → 클로저 → Connection 강참조 순환을 방지한다.
    { [weak self] (content, contentContext, isComplete, error) in
      guard let self else {
        completion(.failure(ConnectionError.cancelled))
        return
      }
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let content else {
        if isComplete {
          completion(.failure(ConnectionError.disconnected))
        } else {
          self.receive(completion: completion)
        }
        return
      }

      self.buffer.append(Data(content))

      // [weak self]: completion 클로저가 receive(upTo:) → NWConnection 콜백에 전달되면
      // NWConnection → 콜백 → completion → self(강참조) → Connection → NWConnection 순환이 형성된다.
      // 두 내부 completion 클로저 모두 [weak self]로 캡처해 이 순환을 차단한다.
      self.receive(upTo: 4) { [weak self] (headerResult) in
        guard let self else {
          completion(.failure(ConnectionError.cancelled))
          return
        }
        switch headerResult {
        case .failure(let error):
          completion(.failure(error))
          return
        case .success:
          break
        }

        let transportPacket = DirectTCPPacket(response: self.buffer)
        let length = Int(transportPacket.protocolLength)
        self.buffer = Data(transportPacket.smb2Message)

        self.receive(upTo: length) { [weak self] (result) in
          guard let self else {
            completion(.failure(ConnectionError.cancelled))
            return
          }
          switch result {
          case .success:
            let data = Data(self.buffer.prefix(length))
            self.buffer = Data(self.buffer.suffix(from: length))

            let reader = ByteReader(data)
            var offset = 0

            var header: Header
            var response = Data()
            repeat {
              header = reader.read()

              switch NTStatus(header.status) {
              case
                .success,
                .moreProcessingRequired,
                .noMoreFiles,
                .endOfFile:
                response += data
              case .pending:
                if self.buffer.count >= 4 {
                  let transportPacket = DirectTCPPacket(response: self.buffer)
                  let length = Int(transportPacket.protocolLength)

                  if self.buffer.count < 4 + length {
                    self.receive(completion: completion)
                    return
                  }

                  let data = transportPacket.smb2Message
                  self.buffer = Data(self.buffer.suffix(from: 4 + length))

                  let reader = ByteReader(data)
                  let header: Header = reader.read()

                  switch NTStatus(header.status) {
                  case
                    .success,
                    .moreProcessingRequired,
                    .noMoreFiles,
                    .endOfFile:
                    response += data
                    break
                  default:
                    completion(.failure(ErrorResponse(data: data)))
                    return
                  }
                } else {
                  self.receive(completion: completion)
                  return
                }
              default:
                completion(.failure(ErrorResponse(data: Data(data[offset...]))))
                return
              }

              offset += Int(header.nextCommand)
              reader.seek(to: offset)
            } while header.nextCommand > 0

            completion(.success(response))
          case .failure(let error):
            completion(.failure(error))
          }
        }
      }
    }
  }

  private func receive(upTo byteCount: Int, completion: @escaping (Result<(), Error>) -> Void) {
    let minimumIncompleteLength = 1
    let maximumLength = 65536

    if self.buffer.count < byteCount {
      // [weak self]: receive(upTo:) 재귀 호출 체인이 NWConnection 콜백 안에 있으므로
      // Connection → NWConnection → 클로저 → Connection 강참조 순환을 방지한다.
      self.connection.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { [weak self] (data, _, isComplete, error) in
        guard let self else {
          completion(.failure(ConnectionError.cancelled))
          return
        }
        if let error = error {
          completion(.failure(error))
          return
        }

        guard let data else {
          if isComplete {
            completion(.failure(ConnectionError.disconnected))
          } else {
            self.receive(upTo: byteCount, completion: completion)
          }
          return
        }

        self.buffer.append(data)
        self.receive(upTo: byteCount, completion: completion)
      }
      return
    }

    completion(.success(()))
  }
}

// MARK: - ContinuationBox -

/// `CheckedContinuation`을 한 번만 resume할 수 있도록 보호하는 헬퍼.
///
/// `withTaskCancellationHandler`의 `onCancel`과 NWConnection의 completion 콜백이
/// 동시에 resume을 시도할 수 있으므로, lock으로 보호된 one-shot 패턴을 적용한다.
///
/// 핵심 사용 패턴:
/// ```swift
/// let box = ContinuationBox<Data>()
/// return try await withTaskCancellationHandler {
///     try await withCheckedThrowingContinuation { continuation in
///         box.set(continuation)
///         if Task.isCancelled { box.resume(with: .failure(CancellationError())); return }
///         startAsyncWork { result in box.resume(with: result) }
///     }
/// } onCancel: {
///     box.resume(with: .failure(CancellationError()))
///     cancelAsyncWork()
/// }
/// ```
private final class ContinuationBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

  func set(_ continuation: CheckedContinuation<T, Error>) {
    lock.withLock { self.continuation = continuation }
  }

  func resume(with result: Result<T, Error>) {
    let c = lock.withLock {
      let c = self.continuation
      self.continuation = nil
      return c
    }
    c?.resume(with: result)
  }
}

public enum ConnectionError: Error {
  case disconnected
  case cancelled
  case unknown
}
