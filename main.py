from fastapi import FastAPI
from fastapi.responses import HTMLResponse

from src.config import config

app = FastAPI(title="Panda-Demo", description="A demo application for Panda")


@app.get("/healthz")
async def health():
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
async def root():
    line_tag = f"<br><b>Version: {config.GIT_TAG}</b>" if config.GIT_TAG else ""
    html_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>Panda Demo</title>
</head>
<body style="font-family: Arial, sans-serif; padding: 20px;">
    <h2>Hello World</h2>
    <p>This is a demo application for Panda Team.</p>
    <p>New Feature</p>
    <p><b>Commit: {config.GIT_SHORT_HASH}</b></p>
    <p>{line_tag}</p>
</body>
</html>"""
    return HTMLResponse(content=html_content)
