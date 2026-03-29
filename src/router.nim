import types

proc addRoute*(app: var Nimbus, path: string, handler: Handler) =
	app.routes.add(Route(path: path, handler: handler))

proc findRoute*(app: Nimbus, path: string): Handler =
	for route in app.routes:
		if route.path == path:
			return route.handler
		return nil
