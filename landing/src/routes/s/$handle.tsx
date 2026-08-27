import { createFileRoute } from "@tanstack/react-router"
import {
  publicSpaceJoinReference,
  spaceJoinPageResponse,
} from "~/lib/spaceJoinPage"

export const Route = createFileRoute("/s/$handle")({
  server: {
    handlers: {
      GET: ({ params }) => spaceJoinPageResponse(publicSpaceJoinReference(params.handle)),
      HEAD: ({ params }) => spaceJoinPageResponse(publicSpaceJoinReference(params.handle), false),
    },
  },
})
