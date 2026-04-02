import std/httpcore
import types

proc httpError*(status: HttpCode, msg: string): HttpError =
  HttpError(status: status, msg: msg)

proc builder*(
  ctx: Context,
  middlewares: seq[Middleware],
  handler: Handler,
  i: int
): Response {.gcsafe async.} =
  if i < middlewares.len:
    let middleware = middlewares[i]
    proc next(): Response {.gcsafe async.} =
      return builder(ctx, middlewares, handler, i + 1)
    return middleware(ctx, next)
  else:
    return handler(ctx)
