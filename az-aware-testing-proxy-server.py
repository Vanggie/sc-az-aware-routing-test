#!/usr/bin/env python3
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.request
import json
import os
import sys
import time

LB_DNS_NAME = os.environ.get('LB_DNS_NAME')

if not LB_DNS_NAME:
    print('ERROR: LB_DNS_NAME environment variable is not set', file=sys.stderr)
    print('Usage: LB_DNS_NAME=<your-alb-dns-name> python3 az-aware-testing-proxy-server.py', file=sys.stderr)
    sys.exit(1)

class ProxyHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/api'):
            try:
                start_time = time.time()
                
                proxy_headers = {
                    'azAwareRouting': 'true',
                    'Connection': 'keep-alive'
                }
                custom_name = self.headers.get('X-Custom-Header-Name')
                custom_value = self.headers.get('X-Custom-Header-Value', '')
                if custom_name:
                    proxy_headers[custom_name] = custom_value

                req = urllib.request.Request(
                    f'http://{LB_DNS_NAME}/',
                    headers=proxy_headers
                )
                with urllib.request.urlopen(req, timeout=5) as response:
                    data = response.read()
                    
                server_latency = int((time.time() - start_time) * 1000)
                
                if server_latency > 500:
                    print(f'HIGH LATENCY: {server_latency}ms at {time.strftime("%H:%M:%S")}')
                    
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('X-Server-Latency', str(server_latency))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                print(f'ERROR: {e}')
                self.send_error(500, str(e))
        else:
            super().do_GET()

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    server = HTTPServer(('localhost', port), ProxyHandler)
    print(f'Server running at http://localhost:{port}')
    print(f'Proxying to: {LB_DNS_NAME}')
    print(f'Open http://localhost:{port}/az-routing-test.html')
    server.serve_forever()
