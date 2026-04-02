import std/posix
import std/net
import std/httpcore
import std/tables
import std/cpuinfo
import types, router

type
  EpollData {.union.} = object
    fd: cint

  EpollEvent {.importc: "struct epoll_event", header: "<sys/epoll.h>", bycopy.} = object
    events: uint32
    data: EpollData

type
  ConnState = enum
    csReading, csParsing, csHandling, csWriting, csClosed

  Connection = ref object
    fd: cint
    state: ConnState

    buffer: array[8192, char]
    bytesRead: int

    writeBuffer: string
    writeOffset: int

    staticResp: cstring
    staticRespLen: int

    httpMethod: HttpMethod

    pathStart: int
    pathLen: int
    bodyStart: int
    bodyLen: int

    keepAlive: bool

proc epoll_create1(flags: cint): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_ctl(epfd, op, fd: cint, event: ptr EpollEvent): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_wait(epfd: cint, events: ptr EpollEvent, maxevents, timeout: cint): cint {.importc, header: "<sys/epoll.h>".}

proc accept4(sockfd: cint, address: ptr SockAddr, address_len: ptr SockLen, flags: cint): cint
  {.importc, header: "<sys/socket.h>".}

const
  EPOLLIN       = 0x001'u32
  EPOLLOUT      = 0x004'u32
  EPOLLET       = 1 shl 31
  EPOLLERR      = 0x008'u32
  EPOLLHUP      = 0x010'u32
  EPOLLRDHUP    = 0x2000'u32
  EPOLL_CTL_ADD = 1.cint
  EPOLL_CTL_DEL = 2.cint
  EPOLL_CTL_MOD = 3.cint
  MAX_EVENTS    = 4096
  SO_REUSEPORT  = 15.cint
  MAX_FD        = 65536

  RESP_404 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

proc toLowerFast(c: char): char {.inline.} =
  char(uint8(c) or 0x20'u8)

proc parseConnectionKeepAlive(data: openArray[char]): bool =
  result = true
  let key = "Connection:"
  for i in 0 .. data.len - key.len - 1:
    var match = true
    for j in 0 ..< key.len:
      if toLowerFast(data[i + j]) != toLowerFast(key[j]):
        match = false
        break
    if match:
      var start = i + key.len
      while start < data.len and data[start] == ' ': inc start
      if start < data.len:
        if toLowerFast(data[start]) == 'c': return false
        if toLowerFast(data[start]) == 'k': return true
  return result

proc parseContentLength(data: openArray[char]): int =
  let key = "Content-Length: "
  for i in 0 .. data.len - key.len - 1:
    var match = true
    for j in 0 ..< key.len:
      if data[i + j] != key[j]:
        match = false
        break
    if match:
      var start = i + key.len
      var n = 0
      while start < data.len and data[start] in {'0'..'9'}:
        n = n * 10 + (ord(data[start]) - ord('0'))
        inc start
      return n
  return 0

proc findEndOfRequest(data: openArray[char]): int =
  for i in 0 .. data.len - 4:
    if data[i] == '\r' and data[i+1] == '\n' and
       data[i+2] == '\r' and data[i+3] == '\n':
      return i + 4
  return -1

proc handleRead(conn: Connection): bool =
  while true:
    let n = recv(SocketHandle(conn.fd),
                 addr conn.buffer[conn.bytesRead],
                 conn.buffer.len - conn.bytesRead, 0)
    if n == 0:
      conn.state = csClosed
      return false
    elif n < 0:
      if errno in [EAGAIN, EWOULDBLOCK]: break
      conn.state = csClosed
      return false
    conn.bytesRead += n
    if conn.bytesRead >= conn.buffer.len:
      conn.state = csClosed
      return false
  conn.state = csParsing
  return true

proc handleParse(conn: Connection): bool =
  let headerEnd = findEndOfRequest(conn.buffer.toOpenArray(0, conn.bytesRead - 1))
  if headerEnd == -1:
    return true

  let data = cast[ptr UncheckedArray[char]](addr conn.buffer[0])

  conn.keepAlive = parseConnectionKeepAlive(conn.buffer.toOpenArray(0, headerEnd - 1))
  let contentLength = parseContentLength(conn.buffer.toOpenArray(0, headerEnd - 1))

  if conn.bytesRead < headerEnd + contentLength:
    return true

  var i = 0

  conn.httpMethod = case data[i]
    of 'G': HttpGet
    of 'D': HttpDelete
    of 'H': HttpHead
    of 'O': HttpOptions
    of 'P':
      if conn.bytesRead > 1 and data[1] == 'O': HttpPost
      elif conn.bytesRead > 1 and data[1] == 'U': HttpPut
      else: HttpPatch
    else: HttpGet

  while i < headerEnd and data[i] != ' ': inc i
  inc i

  conn.pathStart = i
  while i < headerEnd and data[i] != ' ' and data[i] != '\r': inc i
  conn.pathLen = i - conn.pathStart

  conn.bodyStart = headerEnd
  conn.bodyLen = contentLength

  let totalLen = headerEnd + contentLength
  let leftover = conn.bytesRead - totalLen
  if leftover > 0:
    moveMem(addr conn.buffer[0], addr conn.buffer[totalLen], leftover)
  conn.bytesRead = leftover
  conn.state = csHandling
  return true

proc handleRequest(conn: Connection, routers: Table[HttpMethod, RouteNode]) =
  let routeRoot = routers.getOrDefault(conn.httpMethod, nil)
  if routeRoot.isNil:
    conn.staticResp = cstring(RESP_404)
    conn.staticRespLen = RESP_404.len
    conn.writeOffset = 0
    conn.state = csWriting
    return

  let pathStr = newString(conn.pathLen)
  if conn.pathLen > 0:
    copyMem(addr pathStr[0], addr conn.buffer[conn.pathStart], conn.pathLen)

  let handler = findRoute(routeRoot, conn.httpMethod, pathStr)
  if handler.isNil:
    conn.staticResp = cstring(RESP_404)
    conn.staticRespLen = RESP_404.len
    conn.writeOffset = 0
    conn.state = csWriting
    return

  var bodyStr = ""
  if conn.bodyLen > 0:
    bodyStr = newString(conn.bodyLen)
    copyMem(addr bodyStr[0], addr conn.buffer[conn.bodyStart], conn.bodyLen)

  let res = handler(Context(path: pathStr, body: bodyStr))

  let lenStr = $res.body.len
  const h1 = "HTTP/1.1 200 OK\r\nContent-Length: "
  const h2 = "\r\nConnection: keep-alive\r\n\r\n"
  let totalLen = h1.len + lenStr.len + h2.len + res.body.len
  conn.writeBuffer.setLen(totalLen)
  var pos = 0
  copyMem(addr conn.writeBuffer[pos], cstring(h1), h1.len); pos += h1.len
  copyMem(addr conn.writeBuffer[pos], cstring(lenStr), lenStr.len); pos += lenStr.len
  copyMem(addr conn.writeBuffer[pos], cstring(h2), h2.len); pos += h2.len
  if res.body.len > 0:
    copyMem(addr conn.writeBuffer[pos], cstring(res.body), res.body.len)

  conn.staticResp = nil
  conn.writeOffset = 0
  conn.state = csWriting

proc handleWrite(conn: Connection): bool =
  if conn.staticResp != nil:
    while conn.writeOffset < conn.staticRespLen:
      let n = send(SocketHandle(conn.fd),
                   addr conn.staticResp[conn.writeOffset],
                   conn.staticRespLen - conn.writeOffset, 0)
      if n < 0:
        if errno in [EAGAIN, EWOULDBLOCK]: return true
        conn.state = csClosed
        return false
      conn.writeOffset += n
    conn.staticResp = nil
    conn.writeOffset = 0
    conn.state = if conn.keepAlive: csReading else: csClosed
    return true

  while conn.writeOffset < conn.writeBuffer.len:
    let n = send(SocketHandle(conn.fd),
                 addr conn.writeBuffer[conn.writeOffset],
                 conn.writeBuffer.len - conn.writeOffset, 0)
    if n < 0:
      if errno in [EAGAIN, EWOULDBLOCK]: return true
      conn.state = csClosed
      return false
    conn.writeOffset += n

  conn.writeBuffer.setLen(0)
  conn.writeOffset = 0
  conn.state = if conn.keepAlive: csReading else: csClosed
  return true

type
  WorkerArgs = object
    app: Nimbus
    port: int

proc runWorker(args: WorkerArgs) {.thread.} =
  var clients: array[MAX_FD, Connection]
  let localRouters = args.app.routers

  let server_fd = socket(AF_INET, SOCK_STREAM, 0)
  var opt: cint = 1
  discard setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, addr opt, SockLen(sizeof(opt)))
  discard setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, addr opt, SockLen(sizeof(opt)))
  discard setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, addr opt, SockLen(sizeof(opt)))

  var sa: Sockaddr_in
  sa.sin_family      = TSa_Family(posix.AF_INET)
  sa.sin_port        = htons(uint16(args.port))
  sa.sin_addr.s_addr = INADDR_ANY

  discard bindSocket(server_fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa)))
  discard posix.listen(server_fd, SOMAXCONN)
  discard fcntl(cint(server_fd), F_SETFL, O_NONBLOCK)

  let epoll_fd = epoll_create1(0)

  var sev: EpollEvent
  sev.events  = EPOLLIN or EPOLLET
  sev.data.fd = cint(server_fd)
  discard epoll_ctl(epoll_fd, EPOLL_CTL_ADD, cint(server_fd), addr sev)

  var events: array[MAX_EVENTS, EpollEvent]

  while true:
    let ready = epoll_wait(epoll_fd, addr events[0], MAX_EVENTS.cint, -1)
    if ready < 0:
      if errno == EINTR: continue
      continue

    for i in 0 ..< ready.int:
      let fd  = events[i].data.fd
      let evs = events[i].events

      if fd == cint(server_fd):
        while true:
          var sAddr: Sockaddr_in
          var addrLen = SockLen(sizeof(sAddr))
          let cfd = accept4(cint(server_fd), cast[ptr SockAddr](addr sAddr), addr addrLen, O_NONBLOCK)
          if cfd < 0:
            if errno in [EAGAIN, EWOULDBLOCK]: break
            break
          if cfd >= MAX_FD:
            discard close(SocketHandle(cfd))
            continue
          var no: cint = 1
          discard setsockopt(SocketHandle(cfd), IPPROTO_TCP, TCP_NODELAY, addr no, SockLen(sizeof(no)))
          clients[cfd] = Connection(fd: cfd, state: csReading, keepAlive: true)
          var cev: EpollEvent
          cev.events  = EPOLLIN or EPOLLET
          cev.data.fd = cfd
          discard epoll_ctl(epoll_fd, EPOLL_CTL_ADD, cfd, addr cev)
        continue

      let conn = clients[fd]
      if conn.isNil: continue
      if (evs and (EPOLLERR or EPOLLHUP or EPOLLRDHUP)) != 0:
        discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
        discard close(SocketHandle(fd))
        clients[fd] = nil
        continue

      if (evs and EPOLLIN) != 0 and conn.state == csReading:
        if not handleRead(conn):
          discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
          discard close(SocketHandle(fd))
          clients[fd] = nil
          continue

      if conn.state == csParsing:
        if not handleParse(conn):
          discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
          discard close(SocketHandle(fd))
          clients[fd] = nil
          continue

      if conn.state == csHandling:
        handleRequest(conn, localRouters)

      if conn.state == csWriting:
        if (evs and EPOLLOUT) != 0 or conn.staticResp != nil or conn.writeBuffer.len > 0:
          if not handleWrite(conn):
            discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
            discard close(SocketHandle(fd))
            clients[fd] = nil
            continue

        if conn.state == csWriting:
          var mev: EpollEvent
          mev.events  = EPOLLIN or EPOLLOUT or EPOLLET
          mev.data.fd = fd
          discard epoll_ctl(epoll_fd, EPOLL_CTL_MOD, fd, addr mev)
        elif conn.state == csReading:
          var mev: EpollEvent
          mev.events  = EPOLLIN or EPOLLET
          mev.data.fd = fd
          discard epoll_ctl(epoll_fd, EPOLL_CTL_MOD, fd, addr mev)
        else:
          discard epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, nil)
          discard close(SocketHandle(fd))
          clients[fd] = nil


proc listen*(app: Nimbus, port: int = 4444) =
  let numThreads = countProcessors()
  echo "Nimbus listening on http://localhost:", port, " (", numThreads, " workers)"

  var threads = newSeq[Thread[WorkerArgs]](numThreads)
  let args = WorkerArgs(app: app, port: port)

  for i in 0 ..< numThreads:
    createThread(threads[i], runWorker, args)

  joinThreads(threads)