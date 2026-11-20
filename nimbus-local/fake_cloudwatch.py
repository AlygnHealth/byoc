"""A stand-in for CloudWatch Logs' FilterLogEvents, for a nimbus node run locally.

  python3 -I fake_cloudwatch.py stamp EVENTS      # stdin lines -> "<epoch ms>\t<line>" appended to EVENTS
  python3 -I fake_cloudwatch.py serve EVENTS PORT REQUESTS

`serve` answers FilterLogEvents from EVENTS: every quoted or bare term in the
filter pattern must occur in the message, and the event's time must be inside
[startTime, endTime]. Each request body is appended to REQUESTS as one JSON line,
so what nimbus asked for can be read back.
"""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def stamp(events):
    with open(events, "a", encoding="utf-8") as out:
        for line in sys.stdin:
            out.write(f"{int(time.time() * 1000)}\t{line.rstrip(chr(10))}\n")
            out.flush()
            sys.stdout.write(line)
            sys.stdout.flush()

def terms(pattern):
    return [quoted or bare for quoted, bare in re.findall(r'"([^"]*)"|(\S+)', pattern or "")]

def serve(events, port, requests):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            with open(requests, "a", encoding="utf-8") as log:
                log.write(json.dumps({"target": self.headers.get("X-Amz-Target"), "body": body}) + "\n")
            wanted = terms(body.get("filterPattern"))
            start, end = body.get("startTime", 0), body.get("endTime", 2**63)
            found = []
            with open(events, encoding="utf-8") as source:
                for row in source:
                    millis, _, message = row.rstrip("\n").partition("\t")
                    if start <= int(millis) <= end and all(term in message for term in wanted):
                        found.append({"timestamp": int(millis), "message": message, "logStreamName": "local"})
            answer = json.dumps({"events": found[: body.get("limit", 10000)]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-amz-json-1.1")
            self.send_header("Content-Length", str(len(answer)))
            self.end_headers()
            self.wfile.write(answer)

        def log_message(self, *args):
            pass

    ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()

if __name__ == "__main__":
    mode, *rest = sys.argv[1:]
    {"stamp": stamp, "serve": serve}[mode](*rest)
