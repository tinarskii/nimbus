import src/nimbus
import std/httpcore

var app = newNimbus()

app.get("/", proc(ctx: Context): Response =
  return textResponse("Hello, World!").withStatus(Http200))

app.listen(8888)