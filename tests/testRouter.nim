import unittest
import nimbus
import std/tables
import std/asynchttpserver
import std/asyncdispatch

proc newTestCtx(path: string, params: Table[string,string] = initTable[string,string](), body: string = ""): Context =
  Context(path: path, params: params, body: body)

test "returns nil for non-existent route":
  var app = newNimbus()
  check app.findRoute(HttpGet, "/nonexistent").handler == nil

test "finds correct handler for dynamic route":
  var app = newNimbus()

  proc userHandler(ctx: Context): Future[Response] {.async.} =
    return textResponse("User ID: " & ctx.params["id"])

  app.addRoute(HttpGet, "/user/:id", userHandler)
  let (handler, params) = app.findRoute(HttpGet, "/user/123")

  check handler != nil

  var ctx = newTestCtx("/user/123", params)
  let res = waitFor handler(ctx)

  check res.body == "User ID: 123"

test "finds correct handler for static route":
  var app = newNimbus()

  proc homeHandler(ctx: Context): Future[Response] {.async.} =
    return textResponse("Welcome Home!")

  app.addRoute(HttpGet, "/home", homeHandler)
  let (handler, params) = app.findRoute(HttpGet, "/home")

  check handler != nil

  var ctx = newTestCtx("/home", params)
  let res = waitFor handler(ctx)

  check res.body == "Welcome Home!"

test "finds correct handler for POST route":
  var app = newNimbus()

  proc createUser(ctx: Context): Future[Response] {.async.} =
    return textResponse("Creating user with data: " & ctx.body)

  app.addRoute(HttpPost, "/user", createUser)
  let (handler, params) = app.findRoute(HttpPost, "/user")

  check handler != nil

  var ctx = newTestCtx("/user", params, "test")
  let res = waitFor handler(ctx)

  check res.body == "Creating user with data: test"

test "GET and POST same path return different handlers":
  var app = newNimbus()

  proc getHandler(ctx: Context): Future[Response] {.async.} =
    return textResponse("GET")

  proc postHandler(ctx: Context): Future[Response] {.async.} =
    return textResponse("POST")

  app.addRoute(HttpGet, "/user", getHandler)
  app.addRoute(HttpPost, "/user", postHandler)

  var ctx = newTestCtx("/user")

  let resGet = waitFor app.findRoute(HttpGet, "/user").handler(ctx)
  let resPost = waitFor app.findRoute(HttpPost, "/user").handler(ctx)

  check resGet.body == "GET"
  check resPost.body == "POST"