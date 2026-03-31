import std/tables
import std/asynchttpserver
import types

proc newResponse*(body: string, status: HttpCode, headers: Table[string, string]): Response =
  Response(body: body, status: status, headers: headers)

proc setHeader*(res: var Response, key: string, value: string) =
  res.headers[key] = value

proc textResponse*(body: string): Response =
  Response(body: body, status: Http200, headers: initTable[string, string]())

proc jsonResponse*(body: string): Response =
  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  Response(body: body, status: Http200, headers: headers)

proc withStatus*(response: Response, status: HttpCode): Response =
  result = response
  result.status = status
