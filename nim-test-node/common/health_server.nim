import chronos
import chronos/apps/http/httpserver

proc startHealthServer*(port: Port): Future[HttpServerRef] {.async.} =
  ## Start a health server exposing GET /health and GET /ready.
  proc handler(request: RequestFence): Future[HttpResponseRef] {.async.} =
    if request.isErr():
      return defaultResponse()

    let req = request.get()
    if req.meth == MethodGet and (req.uri.path == "/health" or req.uri.path == "/ready"):
      return await req.respond(
        Http200, "ok", HttpTable.init([("Content-Type", "text/plain")])
      )

    return await req.respond(Http404, "Not Found")

  let serverRes = HttpServerRef.new(initTAddress("0.0.0.0:" & $port), handler)
  if serverRes.isErr():
    raise newException(
      CatchableError, "Failed to create health HTTP server: " & $serverRes.error
    )

  let server = serverRes.get()
  server.start()
  return server
