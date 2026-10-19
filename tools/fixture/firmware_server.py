"""Local DNS + existing authenticated image fixture, for isolated firmware tests."""
import runpy, socket, struct, threading

def dns():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', 53))
    while True:
        data, address = sock.recvfrom(4096)
        end = 12
        labels = []
        while data[end]:
            size = data[end]
            labels.append(data[end+1:end+1+size].decode('ascii'))
            end += size+1
        end += 1
        kind, _ = struct.unpack_from('!HH', data, end)
        question = data[12:end+4]
        known = '.'.join(labels) == 'fixture.pocketmanga.test'
        answer = b''
        if known and kind == 1:
            answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4) + socket.inet_aton('127.0.0.1')
        header = data[:2] + struct.pack('!HHHHH', 0x8180 if known else 0x8183, 1, bool(answer), 0, 0)
        sock.sendto(header + question + answer, address)
        print('DNS', '.'.join(labels), kind, flush=True)

threading.Thread(target=dns, daemon=True).start()
runpy.run_path('/work/tools/fixture/server.py', run_name='__main__')
