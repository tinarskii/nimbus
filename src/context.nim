import types

proc newContext*(path: string): Context =
	Context(path: path)
