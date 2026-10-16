#!/usr/bin/env python3
"""Real Java relay + loopback UDP transport. No phone/VPN/audio acceptance claim."""
import os, socket, struct, subprocess, threading, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
JAVA=Path(os.environ.get('LINKMIC_JAVA',str(Path(os.environ['JAVA_HOME'])/'bin/java')))
JAR=Path(os.environ.get('LINKMIC_JAR',str(ROOT/'artifacts/relay.jar')))

def checksum(data):
    if len(data)%2:data+=b'\0'
    total=sum(struct.unpack('!%dH'%(len(data)//2),data))
    while total>>16:total=(total&65535)+(total>>16)
    return (~total)&65535

def packet(port,payload):
    udp=struct.pack('!HHHH',40001,port,8+len(payload),0)+payload
    h=struct.pack('!BBHHHBBH4s4s',0x45,0,20+len(udp),1,0,64,17,0,socket.inet_aton('10.0.0.2'),socket.inet_aton('127.0.0.1'))
    return h[:10]+struct.pack('!H',checksum(h))+h[12:]+udp

def exact(s,n):
    b=b''
    while len(b)<n:
        more=s.recv(n-len(b))
        if not more:raise EOFError('relay EOF detected')
        b+=more
    return b

def start(port,log):
    p=subprocess.Popen([str(JAVA),'-jar',str(JAR),'relay','-p',str(port)],stdout=log,stderr=log)
    for _ in range(100):
        if p.poll() is not None:raise RuntimeError('relay exited before readiness')
        try:s=socket.create_connection(('127.0.0.1',port),timeout=.2);s.settimeout(2);exact(s,4);return p,s
        except OSError:time.sleep(.05)
    p.terminate();p.wait(3);raise TimeoutError('relay not ready')

def main():
    echo=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);echo.bind(('127.0.0.1',0));echo.settimeout(3)
    port=echo.getsockname()[1]
    def serve():
        for _ in range(2):
            data,addr=echo.recvfrom(4096);echo.sendto(data,addr)
    worker=threading.Thread(target=serve);worker.start()
    relay_port=48138
    with (ROOT/'docs/evidence'/os.environ.get('LINKMIC_RELAY_LOG','relay-runtime.log')).open('w') as log:
        p,s=start(relay_port,log)
        try:
            s.sendall(packet(port,b'linkmic-roundtrip-1'))
            header=exact(s,20);length=struct.unpack('!H',header[2:4])[0];body=exact(s,length-20)
            assert body[8:]==b'linkmic-roundtrip-1'
            print('PASS real relay UDP request/response over loopback')
            p.terminate();p.wait(3)
            try:exact(s,1);raise AssertionError('relay exit not detected')
            except (EOFError,ConnectionResetError):print('NEGATIVE relay exit detected; cannot report network available')
        finally:
            s.close()
            if p.poll() is None:p.terminate();p.wait(3)
        p,s=start(relay_port,log)
        try:
            s.sendall(packet(port,b'linkmic-roundtrip-2'))
            header=exact(s,20);body=exact(s,struct.unpack('!H',header[2:4])[0]-20)
            assert body[8:]==b'linkmic-roundtrip-2'
            print('RECOVERY restarted relay forwarded a fresh real UDP response')
            unused=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);unused.bind(('127.0.0.1',0));unused_port=unused.getsockname()[1]
            s.sendall(packet(unused_port,b'no-upstream-response'))
            try:exact(s,20);raise AssertionError('unexpected upstream response')
            except socket.timeout:print('NEGATIVE no upstream response detected by actual receive timeout')
            unused.close()
        finally:
            s.close();p.terminate();p.wait(3)
    worker.join(3);echo.close();assert not worker.is_alive()
    print('PASS relay integration: 2 roundtrips, exit and no-upstream failures observed; no phone claim')
if __name__=='__main__':main()
