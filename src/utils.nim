import std/[asynchttpserver, asyncdispatch]
import types

proc httpError*(status: HttpCode, msg: string): HttpError =
  HttpError(status: status, msg: msg)

proc builder*(
  ctx: Context,
  middlewares: seq[Middleware],
  handler: Handler,
  i: int
): Future[Response] {.gcsafe async.} =
  if i < middlewares.len:
    let middleware = middlewares[i]
    proc next(): Future[Response] {.gcsafe async.} =
      return await builder(ctx, middlewares, handler, i + 1)
    return await middleware(ctx, next)
  else:
    return await handler(ctx)
