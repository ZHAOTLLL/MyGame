#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))


def extract_text(data):
    if isinstance(data, dict):
        if isinstance(data.get("output_text"), str) and data.get("output_text"):
            return data["output_text"]
        output = data.get("output")
        if isinstance(output, list):
            texts = []
            for item in output:
                if not isinstance(item, dict):
                    continue
                content = item.get("content")
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        text = block.get("text")
                        if isinstance(text, str) and text:
                            texts.append(text)
                        elif block.get("type") == "output_text" and isinstance(block.get("text"), str):
                            texts.append(block["text"])
            if texts:
                return "\n".join(texts)
        error = data.get("error")
        if isinstance(error, dict):
            msg = error.get("message")
            if isinstance(msg, str) and msg:
                return "__ERR__:" + msg
        if isinstance(error, str) and error:
            return "__ERR__:" + error
    return None


def main():
    if len(sys.argv) < 2:
      emit({"ok": False, "error": "missing_request_path"})
      return 1

    request_path = sys.argv[1]
    try:
      with open(request_path, "r", encoding="utf-8") as f:
        req = json.load(f)
    except Exception as exc:
      emit({"ok": False, "error": f"bad_request:{exc}"})
      return 1

    api_key = os.environ.get("ARK_API_KEY") or os.environ.get("VOLCENGINE_API_KEY")
    if not api_key:
      emit({"ok": False, "error": "missing_api_key"})
      return 1

    model = req.get("model") or os.environ.get("ARK_MODEL_ID") or os.environ.get("ARK_DEFAULT_MODEL")
    prompt = req.get("prompt", "")
    if not model:
      emit({"ok": False, "error": "missing_model"})
      return 1

    try:
      payload = {
          "model": model,
          "input": [
              {
                  "role": "user",
                  "content": [
                      {
                          "type": "input_text",
                          "text": prompt,
                      }
                  ],
              }
          ],
          "temperature": float(req.get("temperature", 0.2)),
          "max_output_tokens": int(req.get("max_tokens", 128)),
      }
      request = urllib.request.Request(
          "https://ark.cn-beijing.volces.com/api/v3/responses",
          data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
          headers={
              "Content-Type": "application/json",
              "Authorization": "Bearer " + api_key,
          },
          method="POST",
      )
      with urllib.request.urlopen(request, timeout=60) as response:
          data = json.loads(response.read().decode("utf-8"))
      content = extract_text(data)
      if not content:
          emit({"ok": False, "error": "unexpected_response"})
          return 1
      if content.startswith("__ERR__:"):
          emit({"ok": False, "error": content[8:]})
          return 1
      emit({"ok": True, "content": content})
      return 0
    except urllib.error.HTTPError as exc:
      try:
          detail = exc.read().decode("utf-8")
      except Exception:
          detail = ""
      if detail:
          try:
              data = json.loads(detail)
              content = extract_text(data)
              if content and content.startswith("__ERR__:"):
                  emit({"ok": False, "error": content[8:]})
                  return 1
          except Exception:
              pass
      emit({"ok": False, "error": f"HTTP_{exc.code}:{detail}" if detail else f"HTTP_{exc.code}"})
      return 1
    except Exception as exc:
      emit({"ok": False, "error": str(exc)})
      return 1


if __name__ == "__main__":
    raise SystemExit(main())
