import type { Transaction } from "./transaction"
import type { TransactionId } from "./transaction-id"

export type TransactionWrapper = {
  id: TransactionId
  date: Date
  transaction: Transaction
}

export const wrapTransaction = (transaction: Transaction, id: TransactionId, date = new Date()): TransactionWrapper => ({
  id,
  date,
  transaction,
})
