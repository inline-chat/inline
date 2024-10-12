// twilio-verify.ts

interface VerificationServiceResponse {
  sid: string
  accountSid: string
  friendlyName: string
}

interface VerificationResponse {
  sid: string
  serviceSid: string
  accountSid: string
  to: string
  channel: string
  status: string
}

interface VerificationCheckResponse {
  sid: string
  serviceSid: string
  accountSid: string
  to: string
  channel: string
  status: string
  valid: boolean
}

class TwilioVerify {
  private accountSid: string
  private authToken: string
  private serviceSid: string | null
  private baseUrl: string
  private authHeader: string

  constructor(
    accountSid: string,
    authToken: string,
    serviceSid: string | null = null,
  ) {
    this.accountSid = accountSid
    this.authToken = authToken
    this.serviceSid = serviceSid
    this.baseUrl = "https://verify.twilio.com/v2"
    this.authHeader = `Basic ${Buffer.from(
      `${this.accountSid}:${this.authToken}`,
    ).toString("base64")}`
  }

  async sendVerificationToken(
    to: string,
    channel: "sms",
  ): Promise<VerificationResponse> {
    if (!this.serviceSid) {
      throw new Error(
        "Service SID is not set. Create a verification service first.",
      )
    }

    try {
      const response = await fetch(
        `${this.baseUrl}/Services/${this.serviceSid}/Verifications`,
        {
          method: "POST",
          headers: {
            Authorization: this.authHeader,
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: new URLSearchParams({ To: to, Channel: channel }),
        },
      )

      if (!response.ok) {
        const errorData = await response.json()
        throw new Error(
          `HTTP error! status: ${response.status}, message: ${errorData.message}`,
        )
      }

      return (await response.json()) as VerificationResponse
    } catch (error) {
      throw new Error(
        `Failed to send verification token: ${(error as Error).message}`,
      )
    }
  }

  async checkVerificationToken(
    to: string,
    code: string,
  ): Promise<VerificationCheckResponse> {
    if (!this.serviceSid) {
      throw new Error(
        "Service SID is not set. Create a verification service first.",
      )
    }

    try {
      const response = await fetch(
        `${this.baseUrl}/Services/${this.serviceSid}/VerificationCheck`,
        {
          method: "POST",
          headers: {
            Authorization: this.authHeader,
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: new URLSearchParams({ To: to, Code: code }),
        },
      )

      if (!response.ok) {
        const errorData = await response.json()
        throw new Error(
          `HTTP error! status: ${response.status}, message: ${errorData.message}`,
        )
      }

      return (await response.json()) as VerificationCheckResponse
    } catch (error) {
      throw new Error(
        `Failed to check verification token: ${(error as Error).message}`,
      )
    }
  }
}

import {
  TWILIO_AUTH_TOKEN,
  TWILIO_SID,
  TWILIO_VERIFY_SERVICE_SID,
} from "@in/server/env"

export const twilio = new TwilioVerify(
  TWILIO_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_VERIFY_SERVICE_SID,
)
