export const EMAIL_PROVIDER: "SES" | "RESEND" = process.env["EMAIL_PROVIDER"] === "SES" ? "SES" : "RESEND"
