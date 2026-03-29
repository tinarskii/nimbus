import types, context, router
import std/asynchttpserver
import std/asyncdispatch

proc newNimbus*(): Nimbus =
	Nimbus(routes: @[])

proc get*(app: var Nimbus, path: string, handler: Handler): var Nimbus =
	app.addRoute(path, handler)
	return app

proc listen*(app: var Nimbus, port: int) =
	var server = newAsyncHttpServer()

	proc handleRequest(request: Request) {.async.} =
		let context = newContext(request)
		let handler = app.findRoute(request.url.path)

		if handler == nil:
			await request.respond(Http404, "Not Found")
		else:
			let body = handler(context)
			await request.respond(Http200, body)

	proc main() {.async.} =
		server.listen(Port(port))
		echo "Nimbus is listening on port: " & $server.port
		while true:
			if server.shouldAcceptRequest():
				await server.acceptRequest(handleRequest)
			else:
				await sleepAsync(500)

	waitFor main()
