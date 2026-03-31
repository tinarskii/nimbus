import std/tables
import std/asynchttpserver
import std/asyncdispatch

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
  Handler* = proc(ctx: Context): Future[Response] {.closure, gcsafe.}
  ErrorHandler* = proc(ctx: Context, err: ref Exception): Future[Response] {.closure, gcsafe.}
  Next* = proc(): Future[Response] {.closure, gcsafe.}
  Middleware* = proc(ctx: Context, next: Next): Future[Response] {.closure, gcsafe.}
  Route* = object
    path*: string
    handler*: Handler
    requestMethod*: HttpMethod
  RouteNode* = ref object
    children*: Table[string, RouteNode]
    paramChild*: RouteNode
    paramName*: string
    handler*: Handler
  Nimbus* = ref object
    routers*: Table[HttpMethod, RouteNode]
    middlewares*: seq[Middleware]
    onError*: ErrorHandler