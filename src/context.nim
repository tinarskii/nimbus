import types
import std/asynchttpserver
import std/tables

proc newContext*(request: Request, params: Table[string, string], body: string): Context =
  Context(
    path: request.url.path,
    params: params,
    body: body,
  )
