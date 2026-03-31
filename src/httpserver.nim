import posix, net, strutils, asyncdispatch, httpcore, tables, asynchttpserver
import types, router

# ====================== Epoll types & procs ======================
type
  EpollData {.union.} = object
    ptrVal: pointer
    fd: cint
    u32: uint32
    u64: uint64

  EpollEvent {.importc: "struct epoll_event", header: "<sys/epoll.h>", bycopy.} = object
    events: uint32
    data: EpollData

proc epoll_create1(flags: cint): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_ctl(epfd: cint, op: cint, fd: cint, event: ptr EpollEvent): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_wait(epfd: cint, events: ptr EpollEvent, maxevents: cint, timeout: cint): cint {.importc, header: "<sys/epoll.h>".}

const
  EPOLLIN    = 0x001'u32
  EPOLLERR   = 0x008'u32
  EPOLLHUP   = 0x010'u32
  EPOLLRDHUP = 0x2000'u32
  EPOLL_CTL_ADD = 1.cint
  EPOLL_CTL_DEL = 2.cint
  MAX_EVENTS = 4096

proc setNonBlocking(fd: cint): bool =
  let flags = fcntl(fd, F_GETFL, 0)
  if flags == -1: return false
  fcntl(fd, F_SETFL, flags or O_NONBLOCK) != -1

# ====================== Minimal HTTP parser ======================
proc parseMethodAndPath(data: openArray[char]): tuple[httpMethod: HttpMethod, path: string] =
  ## Very fast first-line parser: "GET /api/users HTTP/1.1\r\n..."
  var i = 0
  var methStr = ""

  # Parse method
  while i < data.len and data[i] != ' ':
    methStr.add data[i]
    inc i
  inc i  # skip space

  # Parse path
  var path = ""
  while i < data.len and data[i] != ' ' and data[i] != '\r' and data[i] != '\n':
    path.add data[i]
    inc i

  result.httpMethod = case methStr.toUpperAscii:
    of "GET":    HttpGet
    of "POST":   HttpPost
    of "PUT":    HttpPut
    of "DELETE": HttpDelete
    of "PATCH":  HttpPatch
    of "HEAD":   HttpHead
    of "OPTIONS":HttpOptions
    else:        HttpGet  # fallback

  result.path = if path.len == 0 or path == "/": "/" else: path

# ====================== Nimbus listen (epoll + async) ======================
proc listen*(app: Nimbus, port: int = 4444) {.async.} =
  let server_fd = socket(posix.AF_INET, SOCK_STREAM, 0)
  if cint(server_fd) < 0:
    quit("Failed to create socket: " & $strerror(errno))

  var opt: cint = 1
  discard setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, addr opt, SockLen(sizeof(opt)))

  var server_addr: Sockaddr_in
  server_addr.sin_family = TSa_Family(posix.AF_INET)
  server_addr.sin_addr.s_addr = INADDR_ANY
  server_addr.sin_port = htons(uint16(port))

  if bindSocket(server_fd, cast[ptr SockAddr](addr server_addr), SockLen(sizeof(server_addr))) < 0:
    quit("Failed to bind: " & $strerror(errno))
  if posix.listen(server_fd, SOMAXCONN) < 0:
    quit("Failed to listen: " & $strerror(errno))
  if not setNonBlocking(cint(server_fd)):
    quit("Failed to set non-blocking: " & $strerror(errno))

  let epoll_fd = epoll_create1(0)
  if epoll_fd < 0:
    quit("epoll_create1 failed: " & $strerror(errno))

  var server_event: EpollEvent
  server_event.events = EPOLLIN
  server_event.data.fd = cint(server_fd)
  if epoll_ctl(epoll_fd, EPOLL_CTL_ADD, cint(server_fd), addr server_event) < 0:
    quit("Failed to add server to epoll: " & $strerror(errno))

  var events: array[MAX_EVENTS, EpollEvent]
  var buffer: array[8192, char]  # Fix 1: Single reused buffer to avoid 33.5MB stack allocation

  echo "Nimbus epoll server running at http://localhost:" & $port

  while true:
    # Fix 2: 10ms timeout instead of -1 (blocking) so Nim's async loop doesn't freeze
    let ready = epoll_wait(epoll_fd, addr events[0], MAX_EVENTS.cint, 10)

    if ready < 0:
      if errno == EINTR: continue
      echo "epoll_wait failed: ", strerror(errno)
      await sleepAsync(1)
      continue

    if ready == 0:
      # Yield to Nim's asyncdispatcher if there are no epoll events
      await sleepAsync(1)
      continue

    for i in 0..<ready.int:
      let ev = events[i]
      let fd = ev.data.fd

      # Error or hangup → close
      if (ev.events and (EPOLLERR or EPOLLHUP or EPOLLRDHUP)) != 0:
        discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
        discard close(SocketHandle(fd))
        continue

      # Accept new connections
      if fd == cint(server_fd):
        while true:
          var client_addr: Sockaddr_in
          var addr_len = SockLen(sizeof(client_addr))
          let client_fd = accept(server_fd, cast[ptr SockAddr](addr client_addr), addr addr_len)
          if cint(client_fd) < 0:
            if errno in [EAGAIN, EWOULDBLOCK]: break
            echo "Accept error: ", strerror(errno)
            break

          if not setNonBlocking(cint(client_fd)):
            discard close(client_fd)
            continue

          var client_event: EpollEvent
          client_event.events = EPOLLIN or EPOLLERR or EPOLLHUP or EPOLLRDHUP
          client_event.data.fd = cint(client_fd)
          if epoll_ctl(epoll_fd, EPOLL_CTL_ADD, cint(client_fd), addr client_event) < 0:
            discard close(client_fd)
        continue

      # Read request into the single pooled buffer
      let n = recv(SocketHandle(fd), addr buffer[0], buffer.len, 0)
      if n <= 0:
        discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
        discard close(SocketHandle(fd))
        continue

      let (httpMethod, path) = parseMethodAndPath(buffer[0..n-1])
      let routeRoot = app.routers.getOrDefault(httpMethod, nil)
      if routeRoot.isNil:
        discard send(SocketHandle(fd), cstring("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"), 45, 0)
        discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
        discard close(SocketHandle(fd))
        continue

      let (handler, _) = findRoute(routeRoot, httpMethod, path)
      if handler.isNil:
        discard send(SocketHandle(fd), cstring("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"), 45, 0)
        discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
        discard close(SocketHandle(fd))
        continue

      # Safe string copy from the single buffer
      var ctx = Context(path: path,
                        params: initTable[string,string](),
                        body: newString(n))
      setLen(ctx.body, n)
      for j in 0..<n:
        ctx.body[j] = buffer[j]

      # Dispatch to your async handler
      let res = waitFor handler(ctx)

      # Send response
      let respHeader = "HTTP/1.1 " & $res.status & "\r\nContent-Length: " & $res.body.len & "\r\nConnection: close\r\n\r\n"
      discard send(SocketHandle(fd), cstring(respHeader & res.body), respHeader.len + res.body.len.cint, 0)

      # Close connection
      discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
      discard close(SocketHandle(fd))