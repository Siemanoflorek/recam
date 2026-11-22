"""
RealCam · serwer PC (nasłuch audio).

Odbiera dźwięk z iPhone'a (PCM 16 kHz, mono, Int16) po WebSocket,
liczy poziom głośności (RMS) i pokazuje go na żywo w przeglądarce.
Gdy poziom przekroczy próg -> wypisuje alert w konsoli (tu wepniesz
swój własny alert: mail, powiadomienie, zapis itd.).

Uruchomienie:
    pip install -r requirements.txt
    python server.py

Podgląd:  http://localhost:8000
"""

import json
import math
import array
import socket
from aiohttp import web, WSMsgType

PORT = 8000

# Próg "głośnego dźwięku" (0.0–1.0). Podkręć / obniż wg potrzeb.
LOUD_THRESHOLD = 0.5

viewers = set()


def rms_level(data: bytes) -> float:
    """Zwraca poziom 0.0–1.0 z bloku PCM Int16."""
    samples = array.array("h")  # signed short
    samples.frombytes(data[: len(data) - (len(data) % 2)])
    if not samples:
        return 0.0
    total = 0.0
    for s in samples:
        total += s * s
    rms = math.sqrt(total / len(samples))
    return min(1.0, rms / 32768 * 4)


VIEWER_HTML = """<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RealCam · nasłuch</title>
<style>
  html,body{margin:0;background:#0b0b0d;color:#e8e8ea;font-family:system-ui,sans-serif;height:100%}
  .wrap{max-width:560px;margin:0 auto;padding:40px 20px}
  h1{font-size:22px;margin:0 0 4px}
  .sub{color:#888;font-size:14px;margin-bottom:28px}
  .meter{height:28px;background:#17171c;border-radius:8px;overflow:hidden;border:1px solid #262630}
  .fill{height:100%;width:0;background:#2ecc71;transition:width .08s linear}
  .fill.loud{background:#e74c3c}
  .row{display:flex;justify-content:space-between;margin-top:10px;font-size:14px;color:#aaa}
  .alert{margin-top:24px;padding:14px 16px;border-radius:8px;background:#17171c;border:1px solid #262630;
         font-size:15px;transition:.15s}
  .alert.on{background:#3a1413;border-color:#e74c3c;color:#ff9b93;font-weight:600}
  .thr{position:relative;height:0}
  .thr span{position:absolute;top:-28px;width:2px;height:28px;background:#f1c40f;opacity:.7}
</style>
</head>
<body>
  <div class="wrap">
    <h1>RealCam · nasłuch</h1>
    <div class="sub" id="status">czekam na dźwięk z telefonu…</div>

    <div class="meter">
      <div class="fill" id="fill"></div>
      <div class="thr"><span id="thr"></span></div>
    </div>
    <div class="row"><span>cicho</span><span id="pct">0%</span><span>głośno</span></div>

    <div class="alert" id="alert">Spokojnie — brak głośnych dźwięków.</div>
  </div>
<script>
  const fill = document.getElementById('fill');
  const pct = document.getElementById('pct');
  const status = document.getElementById('status');
  const alert = document.getElementById('alert');
  const thr = document.getElementById('thr');
  let last = 0;

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${proto}://${location.host}/view`);
    ws.onmessage = (e) => {
      const d = JSON.parse(e.data);
      last = Date.now();
      const p = Math.round(d.level * 100);
      fill.style.width = p + '%';
      fill.classList.toggle('loud', d.loud);
      pct.textContent = p + '%';
      status.textContent = 'nasłuch na żywo';
      thr.style.left = Math.round(d.threshold * 100) + '%';
      if (d.loud) {
        alert.textContent = '🔴 GŁOŚNY DŹWIĘK wykryty!';
        alert.classList.add('on');
      } else {
        alert.textContent = 'Spokojnie — brak głośnych dźwięków.';
        alert.classList.remove('on');
      }
    };
    ws.onclose = () => setTimeout(connect, 1000);
  }
  connect();

  setInterval(() => {
    if (Date.now() - last > 1500) {
      status.textContent = 'czekam na dźwięk z telefonu…';
      fill.style.width = '0%'; pct.textContent = '0%';
    }
  }, 1000);
</script>
</body>
</html>
"""


async def index(request):
    return web.Response(text=VIEWER_HTML, content_type="text/html")


async def phone_ws(request):
    """Gniazdo telefonu – przychodzą bloki PCM Int16."""
    ws = web.WebSocketResponse(max_msg_size=16 * 1024 * 1024)
    await ws.prepare(request)
    print(">> Telefon połączony:", request.remote)
    async for msg in ws:
        if msg.type == WSMsgType.BINARY:
            level = rms_level(msg.data)
            loud = level >= LOUD_THRESHOLD

            if loud:
                print(f"!! GŁOŚNY DŹWIĘK  (poziom {level:.2f})")
                # >>> TU WEPNIJ SWÓJ ALERT (mail, powiadomienie, zapis pliku...) <<<

            payload = json.dumps({
                "level": round(level, 3),
                "loud": loud,
                "threshold": LOUD_THRESHOLD,
            })
            dead = []
            for v in viewers:
                try:
                    await v.send_str(payload)
                except Exception:
                    dead.append(v)
            for d in dead:
                viewers.discard(d)
        elif msg.type == WSMsgType.ERROR:
            break
    print("<< Telefon rozłączony")
    return ws


async def viewer_ws(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    viewers.add(ws)
    try:
        async for _ in ws:
            pass
    finally:
        viewers.discard(ws)
    return ws


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def main():
    app = web.Application()
    app.add_routes([
        web.get("/", index),
        web.get("/stream", phone_ws),   # <- telefon
        web.get("/view", viewer_ws),    # <- przeglądarka
    ])
    ip = local_ip()
    print("=" * 50)
    print(" RealCam · serwer nasłuchu wystartował")
    print(f" Podgląd:  http://localhost:{PORT}")
    print(f" W aplikacji wpisz IP:  {ip}   port: {PORT}")
    print(f" Próg alertu (LOUD_THRESHOLD): {LOUD_THRESHOLD}")
    print("=" * 50)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
