import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGmQAAAAASUVORK5CYII=')
class Server(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/page.png' or self.headers.get('X-PocketManga-Fixture') != 'yes':
            self.send_error(403); return
        self.send_response(200)
        self.send_header('Content-Type','image/png')
        self.send_header('Content-Length',str(len(PNG)))
        self.end_headers(); self.wfile.write(PNG)
HTTPServer(('127.0.0.1',8765),Server).serve_forever()
