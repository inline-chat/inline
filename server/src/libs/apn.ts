import APN from "apn"

// Configure APN provider
export const apnProvider = new APN.Provider({
  token: {
    key: Buffer.from(process.env["APN_KEY"] ?? "", "base64").toString("utf-8"),
    keyId: process.env["APN_KEY_ID"] as string,
    teamId: process.env["APN_TEAM_ID"] as string,
  },
  production: process.env["NODE_ENV"] === "production",
})
// Shutdown provider TODO: call on server close
// apnProvider.shutdown()
