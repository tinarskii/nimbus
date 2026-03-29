type
	Handler* = proc(ctx: Context): string
	Context* = object
		path*: string
	Route* = object
		path*: string
		handler*: Handler
	Nimbus* = object
		routes*: seq[Route]
