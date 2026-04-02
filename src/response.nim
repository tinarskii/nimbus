import std/tables
import std/httpcore
import types

proc newResponse*(body: string, status: HttpCode, headers: Table[string, string]): Response =
  Response(body: body, status: status, headers: headers)

proc setHeader*(res: var Response, key: string, value: string) =
  res.headers[key] = value

proc textResponse*(body: string): Response =
  Response(body: body, status: Http200)

proc jsonResponse*(body: string): Response =
  result = Response(body: body, status: Http200)
  result.headers["Content-Type"] = "application/json"

proc withStatus*(response: Response, status: HttpCode): Response =
  result = response
  result.status = status
