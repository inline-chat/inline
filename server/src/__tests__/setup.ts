import { mock } from "bun:test"

// Mock external services for testing
process.env.NODE_ENV = "test"

if (!process.env.RESEND_API_KEY) {
  process.env.RESEND_API_KEY = "test-key"
}

if (!process.env["ENCRYPTION_KEY"]) {
  process.env["ENCRYPTION_KEY"] = "1234567890123456789012345678901212345678901234567890123456789012"
}
// If some services are not needed during testing, you can use dummy values
if (!process.env.AMAZON_ACCESS_KEY) {
  process.env.AMAZON_ACCESS_KEY = "test-key"
}
if (!process.env.AMAZON_SECRET_ACCESS_KEY) {
  process.env.AMAZON_SECRET_ACCESS_KEY = "test-secret"
}
// ... add other environment variables as needed

// You might want to mock external services
mock.module("../libs/resend", () => ({
  sendEmail: mock().mockResolvedValue(true),
}))

// doesn't work
// mock.module("../libs/apn.ts", () => ({
//   apnProvider: mock().mockReturnValue(undefined),
// }))
