from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.auth import get_current_user
from app.db import close_pool, init_pool
from app.routes import admin as admin_router
from app.routes import auth as auth_router
from app.routes import customer as customer_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application lifespan: open DB pool on start, close on shutdown."""
    await init_pool()
    yield
    await close_pool()


app = FastAPI(
    title="Vehicle Parking Management System",
    description="ParkEase - Academic demo project",
    version="1.0.0",
    lifespan=lifespan,
)

# Static files
app.mount("/static", StaticFiles(directory="app/static"), name="static")

# Templates
templates = Jinja2Templates(directory="app/templates")

# Routers
app.include_router(auth_router.router)
app.include_router(customer_router.router, prefix="/customer")
app.include_router(admin_router.router, prefix="/admin")


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Root redirect based on role."""
    user = get_current_user(request)
    if user:
        if user["role"] in ("ADMIN", "FACILITY_ADMIN"):
            return RedirectResponse("/admin/dashboard", status_code=302)
        return RedirectResponse("/customer/dashboard", status_code=302)
    return RedirectResponse("/login", status_code=302)


@app.exception_handler(403)
async def forbidden_handler(request: Request, exc):
    return templates.TemplateResponse(
        request=request,
        name="error.html",
        context={"error": "Access denied. You do not have permission to view this page.", "code": 403},
        status_code=403,
    )


@app.exception_handler(404)
async def not_found_handler(request: Request, exc):
    return templates.TemplateResponse(
        request=request,
        name="error.html",
        context={"error": "The page you are looking for was not found.", "code": 404},
        status_code=404,
    )
