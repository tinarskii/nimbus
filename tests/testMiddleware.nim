import unittest
import nimbus
import std/asyncdispatch
import std/tables
import std/asynchttpserver

proc newTestCtx(path: string, params: Table[string,string] = initTable[string,string](), body: string = ""): Context =
  Context(path: path, params: params, body: body)

test "middleware is applied correctly":
  var app = newNimbus()

  proc logger(ctx: Context, next: Next): Future[Response] {.async, gcsafe.} =
    let res = await next()
    return textResponse("Logged: " & res.body)

  proc handler(ctx: Context): Future[Response] {.gcsafe async.} =
    return textResponse("Handler executed")

  discard app.use(logger)
  app.addRoute(HttpGet, "/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")

  var ctx = newTestCtx("/test", params)
  let res = waitFor builder(ctx, app.middlewares, h, 0)

  check res.body == "Logged: Handler executed"

test "middleware runs before handler":
  var app = newNimbus()

  proc logger(ctx: Context, next: Next): Future[Response] {.gcsafe async.} =
    let res = await next()
    return textResponse("Logged: " & res.body)

  proc handler(ctx: Context): Future[Response] {.async.} =
    return textResponse("Handler executed")

  discard app.use(logger)
  app.addRoute(HttpGet, "/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")

  var ctx = newTestCtx("/test", params)
  let res = waitFor builder(ctx, app.middlewares, h, 0)

  check res.body == "Logged: Handler executed"

test "middleware can block request":
  var app = newNimbus()

  proc auth(ctx: Context, next: Next): Future[Response] {.gcsafe async.} =
    if ctx.params.getOrDefault("auth", "") == "secret":
      return await next()
    else:
      return textResponse("Unauthorized")

  proc handler(ctx: Context): Future[Response] {.gcsafe async.} =
    return textResponse("Handler executed")

  discard app.use(auth)
  app.addRoute(HttpGet, "/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")

  var ctx = newTestCtx("/test", params)
  var res = waitFor builder(ctx, app.middlewares, h, 0)
  check res.body == "Unauthorized"

  ctx.params["auth"] = "secret"
  res = waitFor builder(ctx, app.middlewares, h, 0)
  check res.body == "Handler executed"