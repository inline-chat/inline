import { describe, expect, it } from "bun:test"
import { formatAuthContactConfirmedAlert, formatSignupCompletedAlert } from "./alerts"

describe("signup completion alerts", () => {
  it("includes the finalized profile, username, and available contacts", () => {
    const alert = formatSignupCompletedAlert({
      id: 1234,
      firstName: " Ada ",
      lastName: "Lovelace\nByron",
      username: "ada",
      email: "ada@example.com",
      phoneNumber: "+15555550123",
      pendingSetup: false,
    })

    expect(alert).toBe(
      [
        "Signup completed: [Ada Lovelace Byron @ada](https://admin.inline.chat/users/1234)",
        "name: Ada Lovelace Byron",
        "username: @ada",
        "email: ada@example.com",
        "phone: +15555550123",
      ].join("\n"),
    )
  })

  it("keeps missing optional profile fields explicit", () => {
    const alert = formatSignupCompletedAlert({
      id: 4321,
      firstName: null,
      lastName: null,
      username: null,
      email: null,
      phoneNumber: "+15555550456",
      pendingSetup: false,
    })

    expect(alert).toBe(
      [
        "Signup completed: [User 4321](https://admin.inline.chat/users/4321)",
        "name: not set",
        "username: not set",
        "phone: +15555550456",
      ].join("\n"),
    )
  })

  it("formats contact confirmation as a traceable auth checkpoint", () => {
    const alert = formatAuthContactConfirmedAlert({
      contact: { type: "email", value: "trace@example.com" },
      source: "/v1/verifyEmailCode",
      ip: "203.0.113.10",
      device: {
        clientType: "ios",
        clientVersion: "1.2.3",
        osVersion: "26.0",
        deviceName: "iPhone",
        deviceId: "device-123",
      },
    })

    expect(alert).toBe(
      [
        "Email confirmed: email trace@example.com",
        "flow: signup",
        "account: new",
        "profile: not created",
        "source: /v1/verifyEmailCode",
        "ip: 203.0.113.10",
        "client: ios, 1.2.3, os 26.0, device iPhone, deviceId device-123",
      ].join("\n"),
    )
  })

  it("identifies a completed existing account as a login flow", () => {
    const alert = formatAuthContactConfirmedAlert({
      contact: { type: "phone", value: "+15555550789" },
      user: {
        id: 9876,
        firstName: "Grace",
        lastName: "Hopper",
        username: "grace",
        email: null,
        phoneNumber: "+15555550789",
        pendingSetup: false,
      },
      source: "/v1/verifySmsCode",
    })

    expect(alert).toBe(
      [
        "Phone confirmed: [Grace Hopper @grace](https://admin.inline.chat/users/9876) with phone +15555550789",
        "flow: login",
        "account: existing",
        "profile: complete",
        "source: /v1/verifySmsCode",
        "ip: unknown",
        "client: unknown",
      ].join("\n"),
    )
  })
})
