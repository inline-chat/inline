import { mock } from "bun:test"

// Set test environment
process.env.NODE_ENV = "test"
process.env.RESEND_API_KEY = process.env.RESEND_API_KEY || "test-key"
process.env["ENCRYPTION_KEY"] =
  process.env["ENCRYPTION_KEY"] || "1234567890123456789012345678901212345678901234567890123456789012"
process.env.AMAZON_ACCESS_KEY = process.env.AMAZON_ACCESS_KEY || "test-key"
process.env.AMAZON_SECRET_ACCESS_KEY = process.env.AMAZON_SECRET_ACCESS_KEY || "test-secret"
process.env.SES_ACCESS_KEY_ID = process.env.SES_ACCESS_KEY_ID || "test-key"
process.env.SES_SECRET_ACCESS_KEY = process.env.SES_SECRET_ACCESS_KEY || "test-secret"

// Mock external services
mock.module("../libs/resend", () => ({
  sendEmail: mock().mockResolvedValue(true),
  resend: {
    emails: { send: mock().mockResolvedValue({ data: { id: "test-email" }, error: null }) },
    contacts: {
      get: mock().mockResolvedValue({ data: null, error: { message: "not found" } }),
      create: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      update: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      segments: {
        add: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
        remove: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      },
    },
    segments: { create: mock().mockResolvedValue({ data: { id: "test-segment" }, error: null }) },
    broadcasts: {
      create: mock().mockResolvedValue({ data: { id: "test-broadcast" }, error: null }),
      send: mock().mockResolvedValue({ data: { id: "test-broadcast" }, error: null }),
    },
  },
}))
