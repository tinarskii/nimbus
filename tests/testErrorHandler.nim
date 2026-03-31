import unittest
import nimbus
import std/tables
import std/asynchttpserver
import std/asyncdispatch

proc newTestCtx(path: string, params: Table[string,string] = initTable[string,string](), body: string = ""): Context =
  Context(path: path, params: params, body: body)

test "HttpError returns correct status":
  var app = newNimbus()

  proc handler(ctx: Context): Future[Response] {.async.} =
    raise httpError(Http404, "Not Found")

  app.get("/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")
  var ctx = newTestCtx("/test", params)

  try:
    discard waitFor builder(ctx, app.middlewares, h, 0)
    check false
  except CatchableError as e:
    let res = waitFor app.onError(ctx, e)
    check res.status == Http404

test "unknown error returns 500":
  var app = newNimbus()

  proc handler(ctx: Context): Future[Response] {.async.} =
    raise newException(ValueError, "boom")

  app.get("/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")
  var ctx = newTestCtx("/test", params)

  try:
    discard waitFor builder(ctx, app.middlewares, h, 0)
    check false
  except CatchableError as e:
    let res = waitFor app.onError(ctx, e)
    check res.status == Http500

test "custom onError overrides default":
  var app = newNimbus()

  proc handler(ctx: Context): Future[Response] {.async.} =
    raise newException(ValueError, "boom")

  proc customError(ctx: Context, err: ref Exception): Future[Response] {.gcsafe async.} =
    return textResponse("Custom").withStatus(Http418)

  app.onError = customError
  app.get("/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")
  var ctx = newTestCtx("/test", params)

  try:
    discard waitFor builder(ctx, app.middlewares, h, 0)
    check false
  except CatchableError as e:
    let res = waitFor app.onError(ctx, e)
    check res.status == Http418
    check res.body == "Custom"

test "middleware error is caught":
  var app = newNimbus()

  proc badMw(ctx: Context, next: Next): Future[Response] {.async.} =
    raise newException(ValueError, "middleware fail")

  proc handler(ctx: Context): Future[Response] {.async.} =
    return textResponse("OK")

  discard app.use(badMw)
  app.get("/test", handler)

  let (h, params) = app.findRoute(HttpGet, "/test")
  var ctx = newTestCtx("/test", params)

  try:
    discard waitFor builder(ctx, app.middlewares, h, 0)
    check false
  except CatchableError as e:
    let res = waitFor app.onError(ctx, e)
    check res.status == Http500

test "handler HttpError is caught":
  var app = newNimbus()

  proc handler(ctx: Context): Future[Response] {.async.} =
    raise httpError(Http401, "Unauthorized")

  app.get("/secure", handler)

  let (h, params) = app.findRoute(HttpGet, "/secure")
  var ctx = newTestCtx("/secure", params)

  try:
    discard waitFor builder(ctx, app.middlewares, h, 0)
    check false
  except CatchableError as e:
    let res = waitFor app.onError(ctx, e)
    check res.status == Http401