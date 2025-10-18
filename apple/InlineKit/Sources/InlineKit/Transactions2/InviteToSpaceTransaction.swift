import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct InviteToSpaceTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/InviteToSpace")

  // Properties
  public var method: InlineProtocol.Method = .inviteToSpace
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var spaceId: Int64
    public var access: AccessRole
    public var userID: Int64?
    public var email: String?
    public var phoneNumber: String?

    public enum AccessRole: Sendable, Codable {
      case member(canAccessPublicChats: Bool)
      case admin
    }

    public init(
      spaceId: Int64,
      access: AccessRole,
      userID: Int64? = nil,
      email: String? = nil,
      phoneNumber: String? = nil
    ) {
      self.spaceId = spaceId
      self.access = access
      self.userID = userID
      self.email = email
      self.phoneNumber = phoneNumber
    }
  }

  public init(
    spaceId: Int64,
    access: Context.AccessRole,
    userID: Int64
  ) {
    context = Context(spaceId: spaceId, access: access, userID: userID)
  }

  public init(
    spaceId: Int64,
    access: Context.AccessRole,
    email: String
  ) {
    context = Context(spaceId: spaceId, access: access, email: email)
  }

  public init(
    spaceId: Int64,
    access: Context.AccessRole,
    phoneNumber: String
  ) {
    context = Context(spaceId: spaceId, access: access, phoneNumber: phoneNumber)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .inviteToSpace(.with {
      $0.spaceID = context.spaceId

      $0.role = .with {
        $0.role = switch context.access {
        case let .member(canAccessPublicChats):
          .member(.with {
            $0.canAccessPublicChats = canAccessPublicChats
          })

        case .admin:
          .admin(.init())
        }
      }

      if let userID = context.userID {
        $0.userID = userID
      } else if let email = context.email {
        $0.email = email
      } else if let phoneNumber = context.phoneNumber {
        $0.phoneNumber = phoneNumber
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    // log.debug("Optimistic invite to space")
    // For invite operations, we could show a pending invitation UI state
    // This is left minimal as the actual invitation UI feedback
    // should be handled by the UI layer showing loading states
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .inviteToSpace(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("inviteToSpace result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        // Save user
        if response.hasUser {
          do {
            let user = User(from: response.user)
            try user.save(db)
          } catch {
            log.error("Failed to save user", error: error)
          }
        }

        // Save member
        if response.hasMember {
          do {
            let member = Member(from: response.member)
            try member.save(db)
          } catch {
            log.error("Failed to save member", error: error)
          }
        }

        // Save chat if present
        if response.hasChat {
          do {
            let chat = Chat(from: response.chat)
            try chat.save(db)
          } catch {
            log.error("Failed to save chat", error: error)
          }
        }

        // Save dialog if present
        if response.hasDialog {
          do {
            let dialog = Dialog(from: response.dialog)
            try dialog.save(db)
          } catch {
            log.error("Failed to save dialog", error: error)
          }
        }
      }
      log.trace("inviteToSpace saved")
    } catch {
      log.error("Failed to save inviteToSpace result", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == InviteToSpaceTransaction {
  static func inviteToSpace(
    spaceId: Int64,
    access: InviteToSpaceTransaction.Context.AccessRole,
    userId: Int64
  ) -> InviteToSpaceTransaction {
    InviteToSpaceTransaction(spaceId: spaceId, access: access, userID: userId)
  }

  static func inviteToSpace(
    spaceId: Int64,
    access: InviteToSpaceTransaction.Context.AccessRole,
    email: String
  ) -> InviteToSpaceTransaction {
    InviteToSpaceTransaction(spaceId: spaceId, access: access, email: email)
  }

  static func inviteToSpace(
    spaceId: Int64,
    access: InviteToSpaceTransaction.Context.AccessRole,
    phoneNumber: String
  ) -> InviteToSpaceTransaction {
    InviteToSpaceTransaction(spaceId: spaceId, access: access, phoneNumber: phoneNumber)
  }
}
