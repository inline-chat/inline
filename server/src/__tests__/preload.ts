import { mock } from "bun:test"

// Set test environment
process.env.NODE_ENV = "test"
process.env.RESEND_API_KEY = process.env.RESEND_API_KEY || "test-key"
process.env["ENCRYPTION_KEY"] =
  process.env["ENCRYPTION_KEY"] || "1234567890123456789012345678901212345678901234567890123456789012"
process.env.AMAZON_ACCESS_KEY = process.env.AMAZON_ACCESS_KEY || "test-key"
process.env.AMAZON_SECRET_ACCESS_KEY = process.env.AMAZON_SECRET_ACCESS_KEY || "test-secret"

// Mock external services
mock.module("../libs/resend", () => ({
  sendEmail: mock().mockResolvedValue(true),
}))
