import std/tables
import std/asynchttpserver
import strutils
import types

proc newRouteNode*(): RouteNode =
  RouteNode(children: initTable[string, RouteNode](),paramChild: nil,paramName: "",handler: nil)

proc addRoute*(root: RouteNode,requestMethod: HttpMethod,path: string,handler: Handler) =
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

proc findRoute*(root: RouteNode,requestMethod: HttpMethod,path: string): tuple[handler: Handler, params: Table[string, string]] =
  var node = root
  var params = initTable[string, string]()

  let pathOnly = path.split('?')[0]
  let cleanPath = pathOnly.strip(chars = {'/'})
  let parts = if cleanPath.len == 0: @[] else: cleanPath.split('/')

  for part in parts:
    if node.children.hasKey(part):
      node = node.children[part]
    elif not node.paramChild.isNil:
      params[node.paramChild.paramName] = part
      node = node.paramChild
    else:
      return (nil, params)

  return (node.handler, params)