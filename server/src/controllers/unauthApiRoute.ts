import Elysia, {
  type Static,
  type TSchema,
} from "elysia"
import type { TObject } from "@sinclair/typebox"
import { measureTime } from "@in/server/utils/helpers/measure"
import { getIp } from "@in/server/utils/ip"
import { TMakeApiResponse } from "./apiResponse"

export type UnauthenticatedHandlerContext = {
  ip: string | undefined
  source?: string
}

export const makeUnauthApiRoute = <
  Path extends string,
  ISchema extends TObject,
  OSchema extends TSchema,
>(
  path: Path,
  inputType: ISchema,
  outputType: OSchema,
  method: (
    input: Static<ISchema>,
    context: UnauthenticatedHandlerContext,
  ) => Promise<Static<OSchema>>,
): any => {
  const response = TMakeApiResponse(outputType)
  const getRoute: any = new Elysia({ tags: ["GET"] })
  getRoute.get(
    `${path}`,
    async ({
      query: input,
      server,
      request,
      path: source,
    }: any) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip = getIp(request, server)
      const context = { ip, source }
      const result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      query: inputType,
      response,
    },
  )

  const postRoute: any = new Elysia({ tags: ["POST"] })
  postRoute.post(
    path,
    async ({
      body: input,
      server,
      request,
      path: source,
    }: any) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip = getIp(request, server)
      const context = { ip, source }
      const result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      body: inputType,
      response,
    },
  )

  return (new Elysia() as any)
    .use(getRoute)
    .use(postRoute)
}
