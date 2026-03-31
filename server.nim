import src/nimbus
import asyncdispatch
import asynchttpserver

var app = newNimbus()

app.get("/", proc(ctx: Context): Future[Response] {.async.} =
  return textResponse("Hello, World!").withStatus(Http200))

waitFor app.listen(8888)