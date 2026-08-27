import { createFileRoute } from "@tanstack/react-router"
import {
  privateSpaceJoinReference,
  spaceJoinPageResponse,
} from "~/lib/spaceJoinPage"

export const Route = createFileRoute("/invite/$token")({
  server: {
    handlers: {
      GET: ({ params }) => spaceJoinPageResponse(privateSpaceJoinReference(params.token)),
      HEAD: ({ params }) => spaceJoinPageResponse(privateSpaceJoinReference(params.token), false),
    },
  },
})
