import Testing

@testable import InlineKit

@Suite("InlineKit.CreateThreadExecutor")
struct CreateThreadExecutorTests {
  @Test("createThreadLocally falls back to direct create when no cached reservation exists")
  func testCreateThreadLocallyFallsBackWhenNoCachedReservationExists() async throws {
    let recorder = CreateThreadExecutionRecorder()
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: { nil },
      queuedCreateWithReservation: { reservedChatId in
        await recorder.markReserved(reservedChatId)
        return reservedChatId
      },
      directCreate: {
        await recorder.markDirect()
        return 551
      }
    )

    let chatId = try await executor.create()
    #expect(chatId == 551)
    #expect(await recorder.didRunDirect())
    #expect(await recorder.reservedChatIds() == [])
  }

  @Test("createThreadLocally falls back to direct create when reservation acquisition fails")
  func testCreateThreadLocallyFallsBackWhenReservationAcquisitionFails() async throws {
    let recorder = CreateThreadExecutionRecorder()
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: {
        struct ReservationFailure: Error {}
        throw ReservationFailure()
      },
      queuedCreateWithReservation: { reservedChatId in
        await recorder.markReserved(reservedChatId)
        return reservedChatId
      },
      directCreate: {
        await recorder.markDirect()
        return 552
      }
    )

    let chatId = try await executor.create()
    #expect(chatId == 552)
    #expect(await recorder.didRunDirect())
    #expect(await recorder.reservedChatIds() == [])
  }

  @Test("createThreadLocally uses cached reservation when available")
  func testCreateThreadLocallyUsesCachedReservationWhenAvailable() async throws {
    let recorder = CreateThreadExecutionRecorder()
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: { 777 },
      queuedCreateWithReservation: { reservedChatId in
        await recorder.markReserved(reservedChatId)
        return reservedChatId
      },
      directCreate: {
        await recorder.markDirect()
        return 553
      }
    )

    let chatId = try await executor.create()
    #expect(chatId == 777)
    #expect(await recorder.didRunDirect() == false)
    #expect(await recorder.reservedChatIds() == [777])
  }

  @Test("reserved creation failure does not fall back to a second create")
  func testReservedCreationFailureDoesNotCreateAnotherThread() async throws {
    struct QueuedCreationFailure: Error {}

    let recorder = CreateThreadExecutionRecorder()
    let executor = CreateThreadExecutor(
      reservedChatIdProvider: { 778 },
      queuedCreateWithReservation: { reservedChatId in
        await recorder.markReserved(reservedChatId)
        throw QueuedCreationFailure()
      },
      directCreate: {
        await recorder.markDirect()
        return 554
      }
    )

    do {
      _ = try await executor.create()
      Issue.record("Expected reserved creation to fail")
    } catch is QueuedCreationFailure {
      // Expected. A consumed reservation must retain single creation ownership.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await recorder.didRunDirect() == false)
    #expect(await recorder.reservedChatIds() == [778])
  }
}

private actor CreateThreadExecutionRecorder {
  private var directRan = false
  private var reservedIds: [Int64] = []

  func markDirect() {
    directRan = true
  }

  func markReserved(_ chatId: Int64) {
    reservedIds.append(chatId)
  }

  func didRunDirect() -> Bool {
    directRan
  }

  func reservedChatIds() -> [Int64] {
    reservedIds
  }
}
