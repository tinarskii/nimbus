import std/tables
import std/httpcore
import strutils
import types

proc newRouteNode*(): RouteNode =
  RouteNode(children: initTable[string, RouteNode](), paramChild: nil, paramName: "", handler: nil)

proc addRoute*(root: RouteNode, requestMethod: HttpMethod, path: string, handler: Handler) =
  var node = root
  let cleanPath = path.strip(chars = {'/'})
  let parts = if cleanPath.len == 0: @[] else: cleanPath.split('/')
  for part in parts:
    if part.startsWith(":"):
      if node.paramChild.isNil:
        node.paramChild = newRouteNode()
        node.paramChild.paramName = part[1..^1]
      node = node.paramChild
    else:
      if not node.children.hasKey(part):
        node.children[part] = newRouteNode()
      node = node.children[part]
  node.handler = handler

# ใช้ ptr แทน return tuple เพื่อไม่ copy + ไม่ initTable ทุก request
proc findRoute*(root: RouteNode, requestMethod: HttpMethod, path: string): Handler =
  var node = root

  # หา '?' โดยไม่ split
  var pathEnd = path.len
  for i in 0 ..< path.len:
    if path[i] == '?':
      pathEnd = i
      break

  # walk path โดยไม่ split('/') → ไม่ allocate seq
  var segStart = 0
  # skip leading slash
  while segStart < pathEnd and path[segStart] == '/':
    inc segStart

  while segStart <= pathEnd:
    var segEnd = segStart
    while segEnd < pathEnd and path[segEnd] != '/':
      inc segEnd

    let seg = path[segStart ..< segEnd]  # slice ไม่ allocate ใน Nim (openArray view)

    if seg.len == 0:
      segStart = segEnd + 1
      continue

    if node.children.hasKey(seg):
      node = node.children[seg]
    elif not node.paramChild.isNil:
      node = node.paramChild
    else:
      return nil

    segStart = segEnd + 1

  return node.handler