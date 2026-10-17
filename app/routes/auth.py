from fastapi import APIRouter, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from app.db import get_db
from app.auth import (
    hash_password, verify_password,
    create_session, delete_session, get_current_user,
    SESSION_COOKIE,
)
import psycopg

router = APIRouter(tags=["auth"])
templates = Jinja2Templates(directory="app/templates")


# ---------------------------------------------------------------------------
# GET /login
# ---------------------------------------------------------------------------
@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    """Render the login page, redirecting already-authenticated users."""
    user = get_current_user(request)
    if user:
        if user["role"] == "ADMIN":
            return RedirectResponse("/admin/dashboard", status_code=302)
        return RedirectResponse("/customer/dashboard", status_code=302)
    return templates.TemplateResponse(request=request, name="login.html", context={"user": None})


# ---------------------------------------------------------------------------
# POST /login
# ---------------------------------------------------------------------------
@router.post("/login")
async def login(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
):
    """Authenticate the user and issue a session cookie on success."""
    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT id, name, email, password_hash, role, facility_id FROM users WHERE email = %s",
                (email.lower().strip(),),
            )
            row = await cur.fetchone()

        if not row or not verify_password(password, row["password_hash"]):
            return templates.TemplateResponse(
                request=request,
                name="login.html",
                context={"error": "Invalid email or password.", "user": None},
                status_code=400,
            )

        facility_id = str(row["facility_id"]) if row.get("facility_id") else None
        token = create_session(
            str(row["id"]), row["email"], row["name"], row["role"],
            facility_id=facility_id,
        )
        # Both ADMIN and FACILITY_ADMIN use the admin UI
        redirect_url = (
            "/admin/dashboard"
            if row["role"] in ("ADMIN", "FACILITY_ADMIN")
            else "/customer/dashboard"
        )
        response = RedirectResponse(redirect_url, status_code=302)
        response.set_cookie(SESSION_COOKIE, token, httponly=True, samesite="lax")
        return response

    except Exception as e:
        return templates.TemplateResponse(
            request=request,
            name="login.html",
            context={"error": f"Login error: {str(e)}", "user": None},
            status_code=500,
        )


# ---------------------------------------------------------------------------
# GET /register
# ---------------------------------------------------------------------------
@router.get("/register", response_class=HTMLResponse)
async def register_page(request: Request):
    """Render the registration page, redirecting already-authenticated users."""
    user = get_current_user(request)
    if user:
        return RedirectResponse("/customer/dashboard", status_code=302)
    return templates.TemplateResponse(request=request, name="register.html", context={"user": None})


# ---------------------------------------------------------------------------
# POST /register
# ---------------------------------------------------------------------------
@router.post("/register")
async def register(
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    password: str = Form(...),
    confirm_password: str = Form(...),
):
    """Validate form data, create a new CUSTOMER account, and issue a session cookie."""
    if password != confirm_password:
        return templates.TemplateResponse(
            request=request,
            name="register.html",
            context={"error": "Passwords do not match.", "user": None},
            status_code=400,
        )
    if len(password) < 6:
        return templates.TemplateResponse(
            request=request,
            name="register.html",
            context={"error": "Password must be at least 6 characters.", "user": None},
            status_code=400,
        )

    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT id FROM users WHERE email = %s",
                (email.lower().strip(),),
            )
            existing = await cur.fetchone()
            if existing:
                return templates.TemplateResponse(
                    request=request,
                    name="register.html",
                    context={"error": "Email already registered.", "user": None},
                    status_code=400,
                )

            password_hash = hash_password(password)
            cur = await conn.execute(
                """
                INSERT INTO users (name, email, password_hash, role)
                VALUES (%s, %s, %s, 'CUSTOMER')
                RETURNING id, name, email, role
                """,
                (name.strip(), email.lower().strip(), password_hash),
            )
            row = await cur.fetchone()

        token = create_session(str(row["id"]), row["email"], row["name"], row["role"])
        response = RedirectResponse("/customer/dashboard", status_code=302)
        response.set_cookie(SESSION_COOKIE, token, httponly=True, samesite="lax")
        return response

    except psycopg.errors.UniqueViolation:
        return templates.TemplateResponse(
            request=request,
            name="register.html",
            context={"error": "Email already registered.", "user": None},
            status_code=400,
        )
    except Exception as e:
        return templates.TemplateResponse(
            request=request,
            name="register.html",
            context={"error": f"Registration error: {str(e)}", "user": None},
            status_code=500,
        )


# ---------------------------------------------------------------------------
# GET /logout
# ---------------------------------------------------------------------------
@router.get("/logout")
async def logout(request: Request):
    """Invalidate the current session and clear the session cookie."""
    token = request.cookies.get(SESSION_COOKIE)
    if token:
        delete_session(token)
    response = RedirectResponse("/login", status_code=302)
    response.delete_cookie(SESSION_COOKIE)
    return response
