import types, context, router, response, httpserver
import std/[asynchttpserver, asyncdispatch, tables]

proc defaultErrorHandler*(ctx: Context, error: ref Exception): Future[Response] {.gcsafe async.} =
  if error of HttpError:
    let httpErr = HttpError(error)
    return textResponse(httpErr.msg).withStatus(httpErr.status)
  else:
    return textResponse("Internal Server Error").withStatus(Http500)

proc newNimbus*(): Nimbus =
  Nimbus(routers: initTable[HttpMethod, RouteNode](),middlewares: @[],onError: defaultErrorHandler)

proc ensureRoot(app: Nimbus, httpMethod: HttpMethod): RouteNode =
  if not app.routers.hasKey(httpMethod):
    app.routers[httpMethod] = newRouteNode()
  return app.routers[httpMethod]

proc addRoute*(app: Nimbus, httpMethod: HttpMethod, path: string, handler: Handler) =
  let root = app.ensureRoot(httpMethod)
  addRoute(root, httpMethod, path, handler)

proc findRoute*(app: Nimbus, httpMethod: HttpMethod, path: string): tuple[handler: Handler, params: Table[string, string]] =
  if not app.routers.hasKey(httpMethod):
    return (nil, initTable[string, string]())
  return findRoute(app.routers[httpMethod], httpMethod, path)

proc get*(app: Nimbus, path: string, handler: Handler): Nimbus {.discardable.} =
  app.addRoute(HttpGet, path, handler)
  return app

proc post*(app: Nimbus, path: string, handler: Handler): Nimbus {.discardable.} =
  app.addRoute(HttpPost, path, handler)
  return app

proc use*(app: Nimbus, middleware: Middleware): Nimbus {.discardable.} =
  app.middlewares.add(middleware)
  return app

proc `onError=`*(app: Nimbus, errorHandler: ErrorHandler) =
  app.onError = errorHandler

# proc toHttpHeaders(headers: Table[string, string]): HttpHeaders =
#   var httpHeaders = newHttpHeaders()
#   for key, value in headers:
#     httpHeaders[key] = value
#   return httpHeaders

# proc listen*(app: Nimbus, port: int) =
#   var server = newAsyncHttpServer()
#
#   proc handleRequest(request: Request) {.async gcsafe.} =
#     let (handler, params) = app.findRoute(request.reqMethod, request.url.path)
#     var ctx = newContext(request, params, request.body)
#
#     try:
#       if handler.isNil:
#         raise httpError(Http404, "Not Found")
#
#       let res = await builder(ctx, app.middlewares, handler, 0)
#
#       await request.respond(
#         res.status,
#         res.body,
#         res.headers.toHttpHeaders()
#       )
#
#     except CatchableError as e:
#       let errRes =
#         if app.onError != nil:
#           await app.onError(ctx, e)
#         else:
#           textResponse("Internal Server Error").withStatus(Http500)
#
#       await request.respond(
#         errRes.status,
#         errRes.body,
#         errRes.headers.toHttpHeaders()
#       )
#
#   proc main() {.async.} =
#     server.listen(Port(port))
#     echo "Nimbus is listening on port: " & $server.getPort.uint16
#
#     while true:
#       if server.shouldAcceptRequest():
#         await server.acceptRequest(handleRequest)
#       else:
#         await sleepAsync(5)
#
#   waitFor main()

export types, context, router, response, httpserver