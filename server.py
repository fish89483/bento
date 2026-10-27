"""Local static server and shared JSON API for Bento testing."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import RLock
import json
import os
import tempfile


ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "dist"
DATA_FILE = Path(os.environ.get("BENTO_DATA_FILE", ROOT / "bento-data.json"))
DATA_LOCK = RLock()


def merge_state(current, incoming):
    """Keep append-only records from concurrent browser saves."""
    if not current:
        return incoming
    current_data = current.get("data", {})
    incoming_data = incoming.get("data", {})
    people = list(current_data.get("people", []))
    for person in incoming_data.get("people", []):
        if person not in people:
            people.append(person)
    items = list(current_data.get("items", []))
    by_id = {item.get("id"): item for item in items}
    for incoming_item in incoming_data.get("items", []):
        item_id = incoming_item.get("id")
        if item_id not in by_id:
            copied = dict(incoming_item)
            items.append(copied)
            by_id[item_id] = copied
            continue
        item = by_id[item_id]
        incoming_meals = incoming_item.get("meals", [])
        meals = item.setdefault("meals", [])
        meal_ids = {meal.get("id") for meal in meals}
        meals.extend(meal for meal in incoming_meals if meal.get("id") not in meal_ids)
        for key, value in incoming_item.items():
            if key != "meals":
                item[key] = value
    accounts = list(current.get("accounts", []))
    known_emails = {str(account.get("email", "")).lower() for account in accounts}
    for account in incoming.get("accounts", []):
        email = str(account.get("email", "")).lower()
        if email not in known_emails:
            accounts.append(account)
            known_emails.add(email)
    return {"data": {**current_data, **incoming_data, "people": people, "items": items}, "accounts": accounts}


class BentoHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(BUILD), **kwargs)

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/state":
            with DATA_LOCK:
                if DATA_FILE.exists():
                    try:
                        state = json.loads(DATA_FILE.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError):
                        return self._send_json(500, {"error": "本機資料檔無法讀取"})
                else:
                    state = None
            return self._send_json(200, {"state": state})
        return super().do_GET()

    def do_PUT(self):
        if self.path != "/api/state":
            return self._send_json(404, {"error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 10_000_000:
                return self._send_json(413, {"error": "資料大小不正確"})
            state = json.loads(self.rfile.read(length).decode("utf-8"))
            data = state.get("data")
            accounts = state.get("accounts")
            if not isinstance(data, dict) or not isinstance(data.get("items"), list) or not isinstance(data.get("people"), list) or not isinstance(accounts, list):
                return self._send_json(400, {"error": "資料格式不正確"})
            with DATA_LOCK:
                if DATA_FILE.exists():
                    try:
                        current = json.loads(DATA_FILE.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError):
                        current = None
                    state = merge_state(current, state)
                DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
                fd, temp_path = tempfile.mkstemp(prefix="bento-data-", suffix=".tmp", dir=DATA_FILE.parent)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as output:
                        json.dump({"data": data, "accounts": accounts}, output, ensure_ascii=False, indent=2)
                        output.flush()
                        os.fsync(output.fileno())
                    os.replace(temp_path, DATA_FILE)
                finally:
                    if os.path.exists(temp_path):
                        os.unlink(temp_path)
            return self._send_json(200, {"ok": True})
        except (ValueError, UnicodeDecodeError, OSError):
            return self._send_json(400, {"error": "無法儲存資料"})


if __name__ == "__main__":
    if not (BUILD / "index.html").is_file():
        raise SystemExit("Bento 尚未建置，請先執行 npm run build。")
    host = os.environ.get("BENTO_HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8001"))
    server = ThreadingHTTPServer((host, port), BentoHandler)
    server.daemon_threads = True
    print(f"Bento is running at http://{host}:{port}")
    server.serve_forever()
