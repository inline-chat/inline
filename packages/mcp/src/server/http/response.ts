export function text(status: number, body: string, init?: Omit<ResponseInit, "status">): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      ...(init?.headers ?? {}),
    },
  })
}

export function html(status: number, body: string, init?: Omit<ResponseInit, "status">): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      ...(init?.headers ?? {}),
    },
  })
}

export function withJson(value: unknown, init?: Omit<ResponseInit, "status"> & { status?: number }): Response {
  return new Response(JSON.stringify(value), {
    status: init?.status ?? 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...(init?.headers ?? {}),
    },
  })
}

export function badRequest(message: string): Response {
  return withJson({ error: "bad_request", error_description: message }, { status: 400 })
}

export function unauthorized(message = "unauthorized"): Response {
  return withJson({ error: "unauthorized", error_description: message }, { status: 401 })
}

export function notFound(): Response {
  return text(404, "Not found")
}

