# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest

import Nimbus

test "Can find route that had been added":
	var app = Nimbus(routes: @[])
	proc handler(ctx: Context): string = "Hello, World!"

	app.addRoute("/", handler)

	check app.findRoute("/") != nil
