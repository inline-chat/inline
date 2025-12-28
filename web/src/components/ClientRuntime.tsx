import { useEffect } from "react"
import { useAuthState } from "@inline/client"
import { getApiBaseUrl } from "@inline/config"
import { ApiClient } from "~/modules/api"

export function ClientRuntime() {
  const authState = useAuthState()

  useEffect(() => {
    ApiClient.setBaseUrl(getApiBaseUrl())
  }, [])

  useEffect(() => {
    ApiClient.setToken(authState.token)
  }, [authState.token])

  return null
}
