import logging

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import api_auth, api_misc, api_models
from .config import settings
from .db import create_schema, init_engine
from .seed import seed_defaults

logging.basicConfig(level=logging.INFO, format="%(asctime)s api %(levelname)s %(message)s")

init_engine()
create_schema()
seed_defaults()

app = FastAPI(title="3DVault", version="1.0.0", docs_url="/api/docs", openapi_url="/api/openapi.json")
app.include_router(api_auth.router)
app.include_router(api_models.router)
app.include_router(api_misc.router)


@app.get("/api/health")
def health():
    return {"ok": True}


@app.exception_handler(ValueError)
async def value_error(_: Request, exc: ValueError):
    return JSONResponse({"detail": str(exc)}, status_code=400)


# Serve the built React app; unknown non-API paths fall back to index.html for client routing.
if (settings.web_dir / "index.html").exists():
    app.mount("/assets", StaticFiles(directory=settings.web_dir / "assets"), name="assets")

    @app.get("/{path:path}", include_in_schema=False)
    def spa(path: str):
        if path.startswith("api/"):
            return JSONResponse({"detail": "Not found"}, status_code=404)
        candidate = (settings.web_dir / path).resolve()
        if path and candidate.is_file() and settings.web_dir.resolve() in candidate.parents:
            return FileResponse(candidate)
        return FileResponse(settings.web_dir / "index.html", headers={"Cache-Control": "no-cache"})
