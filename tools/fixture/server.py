import base64, os, ssl, struct, zlib, random, time, threading, pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
# A deterministic ~1 MiB PNG per page makes emulator measurements useful.
def chunk(kind, data):
    return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
rng=random.Random(424242)
pixels=b''.join(b'\0'+rng.randbytes(512*4) for _ in range(512))
PNG=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',512,512,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')

seen_stall=False
seen_lock=threading.Lock()
class Server(BaseHTTPRequestHandler):
    def do_GET(self):
        global seen_stall
        if self.path.startswith('/metadata/'):
            if 'zstd' not in self.headers.get('Accept-Encoding', ''):
                self.send_error(406); return
            encoded=pathlib.Path(__file__).with_name('metadata.zst').read_bytes()
            self.send_response(200)
            self.send_header('Content-Type','text/plain; charset=utf-8')
            self.send_header('Content-Encoding','zstd')
            self.send_header('Content-Length',str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path.startswith('/redirect'):
            self.send_response(302)
            self.send_header('Location',self.path.replace('/redirect','/page.png'))
            self.send_header('Content-Length','0')
            self.end_headers()
            return
        if not self.path.startswith('/page.png') or self.headers.get('X-PocketManga-Fixture') != 'yes' or self.headers.get('Cookie') != 'fixture-session=accepted; fixture-extra=present' or not self.headers.get('Referer', '').endswith('/chapter/1'):
            self.send_error(403); return
        self.send_response(200)
        self.send_header('Content-Type','image/png')
        self.send_header('Content-Length',str(len(PNG)))
        self.end_headers()
        with seen_lock:
            stall = self.path.startswith('/page.png?1&stallonce') and not seen_stall
            if stall: seen_stall=True
        if stall:
            self.wfile.write(PNG[:65536]); self.wfile.flush()
            print('Stalling mid-body for cancellation',flush=True)
            time.sleep(10)
            return
        self.wfile.write(PNG)
server=ThreadingHTTPServer(('127.0.0.1',8765),Server)
if os.environ.get('POCKETMANGA_FIXTURE_TLS_CERT'):
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.environ['POCKETMANGA_FIXTURE_TLS_CERT'],os.environ['POCKETMANGA_FIXTURE_TLS_KEY'])
    server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()
