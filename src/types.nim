import std/tables
import std/httpcore
# import std/options

type
  Context* = ref object
    path*: string
    params*: Table[string, string]
    body*: string
  Response* = object
    body*: string
    status*: HttpCode
    headers*: Table[string, string]
  HttpError* = ref object of CatchableError
    status*: HttpCode
  Handler* = proc(ctx: Context): Response {.closure, gcsafe.}
  ErrorHandler* = proc(ctx: Context, err: ref Exception): Response {.closure, gcsafe.}
  Next* = proc(): Response {.closure, gcsafe.}
  Middleware* = proc(ctx: Context, next: Next): Response {.closure, gcsafe.}
  Route* = object
    path*: string
    handler*: Handler
    requestMethod*: HttpMethod
  RouteNode* = ref object
    children*: Table[string, RouteNode]
    paramChild*: RouteNode
    paramName*: string
    handler*: Handler
  ClientContext* = ref object
    buffer*: array[16384, char]
    bytesRead*: int
    writeBuffer*: string
    writeOffset*: int
  Nimbus* = ref object
    routers*: Table[HttpMethod, RouteNode]
    middlewares*: seq[Middleware]
    onError*: ErrorHandler