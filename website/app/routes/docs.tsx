import { redirect } from "@remix-run/node"

export const loader = async () => {
  return redirect("https://inlinehq.notion.site")
}
