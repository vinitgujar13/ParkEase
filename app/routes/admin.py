from typing import Optional

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from app.auth import get_current_user, hash_password
from app.db import get_db

router = APIRouter(tags=["admin"])
templates = Jinja2Templates(directory="app/templates")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def require_admin(request: Request) -> Optional[dict]:
    """Allow ADMIN (super) and FACILITY_ADMIN (scoped) roles through."""
    user = get_current_user(request)
    if not user or user["role"] not in ("ADMIN", "FACILITY_ADMIN"):
        return None
    return user


def is_super_admin(user: dict) -> bool:
    """True only for the global ADMIN role."""
    return user["role"] == "ADMIN"


def facility_filter(user: dict):
    """
    Returns (has_filter: bool, facility_id: str | None).

    Super-admin → no filter.
    Facility-admin → restrict to their facility_id.
    """
    if user["role"] == "FACILITY_ADMIN":
        return True, user.get("facility_id")
    return False, None


# ---------------------------------------------------------------------------
# GET /admin/dashboard
# ---------------------------------------------------------------------------
@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        # Spot stats (scoped if FACILITY_ADMIN)
        if scoped:
            cur = await conn.execute(
                """
                SELECT
                    COUNT(*)                                                 AS total_spots,
                    SUM(CASE WHEN ps.status = 'AVAILABLE'   THEN 1 ELSE 0 END) AS available,
                    SUM(CASE WHEN ps.status = 'OCCUPIED'    THEN 1 ELSE 0 END) AS occupied,
                    SUM(CASE WHEN ps.status = 'RESERVED'    THEN 1 ELSE 0 END) AS reserved,
                    SUM(CASE WHEN ps.status = 'MAINTENANCE' THEN 1 ELSE 0 END) AS maintenance
                FROM parking_spots ps
                JOIN parking_zones pz ON pz.id = ps.zone_id
                WHERE pz.facility_id = %s
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                """
                SELECT
                    COUNT(*)                                                 AS total_spots,
                    SUM(CASE WHEN status = 'AVAILABLE'   THEN 1 ELSE 0 END) AS available,
                    SUM(CASE WHEN status = 'OCCUPIED'    THEN 1 ELSE 0 END) AS occupied,
                    SUM(CASE WHEN status = 'RESERVED'    THEN 1 ELSE 0 END) AS reserved,
                    SUM(CASE WHEN status = 'MAINTENANCE' THEN 1 ELSE 0 END) AS maintenance
                FROM parking_spots
                """
            )
        spot_stats = await cur.fetchone()

        # Active sessions count
        if scoped:
            cur = await conn.execute(
                """
                SELECT COUNT(*) AS cnt FROM parking_sessions ps
                JOIN parking_spots sp ON sp.id = ps.spot_id
                JOIN parking_zones pz ON pz.id = sp.zone_id
                WHERE ps.status = 'ACTIVE' AND pz.facility_id = %s
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                "SELECT COUNT(*) AS cnt FROM parking_sessions WHERE status = 'ACTIVE'"
            )
        active_sessions = (await cur.fetchone())["cnt"]

        # Confirmed reservations count
        if scoped:
            cur = await conn.execute(
                """
                SELECT COUNT(*) AS cnt FROM reservations r
                JOIN parking_spots sp ON sp.id = r.spot_id
                JOIN parking_zones pz ON pz.id = sp.zone_id
                WHERE r.status = 'CONFIRMED' AND pz.facility_id = %s
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                "SELECT COUNT(*) AS cnt FROM reservations WHERE status = 'CONFIRMED'"
            )
        confirmed_reservations = (await cur.fetchone())["cnt"]

        # Total revenue
        if scoped:
            cur = await conn.execute(
                """
                SELECT COALESCE(SUM(p.amount), 0) AS total
                FROM payments p
                JOIN parking_sessions pss ON pss.id = p.session_id
                JOIN parking_spots sp ON sp.id = pss.spot_id
                JOIN parking_zones pz ON pz.id = sp.zone_id
                WHERE p.status = 'PAID' AND pz.facility_id = %s
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                "SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE status = 'PAID'"
            )
        total_revenue = (await cur.fetchone())["total"]

        # Total customers (always global — only super admin sees this)
        cur = await conn.execute(
            "SELECT COUNT(*) AS cnt FROM users WHERE role = 'CUSTOMER'"
        )
        total_customers = (await cur.fetchone())["cnt"]

        # Recent sessions (scoped)
        if scoped:
            cur = await conn.execute(
                """
                SELECT
                    ps.id,
                    v.license_plate,
                    v.vehicle_type,
                    gt.name          AS entry_terminal,
                    ps.entry_time,
                    ps.status,
                    pf.name          AS facility_name
                FROM parking_sessions ps
                JOIN vehicles          v  ON v.id  = ps.vehicle_id
                JOIN gate_terminals    gt ON gt.id = ps.entry_terminal_id
                JOIN parking_spots     sp ON sp.id = ps.spot_id
                JOIN parking_zones     pz ON pz.id = sp.zone_id
                JOIN parking_facilities pf ON pf.id = pz.facility_id
                WHERE pz.facility_id = %s
                ORDER BY ps.entry_time DESC
                LIMIT 5
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                """
                SELECT
                    ps.id,
                    v.license_plate,
                    v.vehicle_type,
                    gt.name          AS entry_terminal,
                    ps.entry_time,
                    ps.status,
                    pf.name          AS facility_name
                FROM parking_sessions ps
                JOIN vehicles          v  ON v.id  = ps.vehicle_id
                JOIN gate_terminals    gt ON gt.id = ps.entry_terminal_id
                JOIN parking_spots     sp ON sp.id = ps.spot_id
                JOIN parking_zones     pz ON pz.id = sp.zone_id
                JOIN parking_facilities pf ON pf.id = pz.facility_id
                ORDER BY ps.entry_time DESC
                LIMIT 5
                """
            )
        recent_sessions = await cur.fetchall()

        # Expire overdue reservations
        await conn.execute("SELECT expire_reservations()")

    return templates.TemplateResponse(
        request=request,
        name="admin/dashboard.html",
        context={
            "user": user,
            "spot_stats": spot_stats,
            "active_sessions": active_sessions,
            "confirmed_reservations": confirmed_reservations,
            "total_revenue": total_revenue,
            "total_customers": total_customers,
            "recent_sessions": recent_sessions,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/reservations
# ---------------------------------------------------------------------------
@router.get("/reservations", response_class=HTMLResponse)
async def reservations(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        await conn.execute("SELECT expire_reservations()")

        base_sql = """
            SELECT
                r.id,
                r.status,
                r.start_time,
                r.created_at,
                u.name           AS customer_name,
                u.email,
                v.license_plate,
                v.vehicle_type,
                pf.name          AS facility_name,
                pz.name          AS zone_name,
                ps.spot_number
            FROM reservations r
            JOIN users          u  ON u.id  = r.user_id
            JOIN vehicles       v  ON v.id  = r.vehicle_id
            JOIN parking_spots  ps ON ps.id = r.spot_id
            JOIN parking_zones  pz ON pz.id = ps.zone_id
            JOIN parking_facilities pf ON pf.id = pz.facility_id
            WHERE r.status IN ('CONFIRMED', 'ACTIVE')
        """
        if scoped:
            cur = await conn.execute(base_sql + " AND pz.facility_id = %s ORDER BY r.created_at DESC", (fid,))
        else:
            cur = await conn.execute(base_sql + " ORDER BY r.created_at DESC")
        all_reservations = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/reservations.html",
        context={
            "user": user,
            "reservations": all_reservations,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/entry  –  show entry form
# ---------------------------------------------------------------------------
@router.get("/entry", response_class=HTMLResponse)
async def entry_page(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        if scoped:
            cur = await conn.execute(
                """
                SELECT gt.id, gt.name FROM gate_terminals gt
                WHERE gt.terminal_type = 'ENTRY' AND gt.facility_id = %s ORDER BY gt.name
                """,
                (fid,),
            )
        else:
            cur = await conn.execute(
                "SELECT id, name FROM gate_terminals WHERE terminal_type = 'ENTRY' ORDER BY name"
            )
        terminals = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/entry.html",
        context={
            "user": user,
            "terminals": terminals,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


# ---------------------------------------------------------------------------
# POST /admin/entry  –  record vehicle entry
# ---------------------------------------------------------------------------
@router.post("/entry")
async def process_entry(
    request: Request,
    reservation_id: str = Form(...),
    license_plate: str = Form(...),
    entry_terminal_id: str = Form(...),
):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    license_plate = license_plate.upper().strip()
    reservation_id = reservation_id.strip()

    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT process_vehicle_entry(%s, %s, %s) AS session_id",
                (reservation_id, license_plate, entry_terminal_id),
            )
            result = await cur.fetchone()
            session_id = result["session_id"]

        return RedirectResponse(
            f"/admin/entry?success=Vehicle+entry+recorded.+Session+ID%3A+{session_id}",
            status_code=302,
        )

    except Exception as exc:
        error_msg = str(exc).split("\n")[0]
        scoped, fid = facility_filter(user)
        async with get_db() as conn:
            if scoped:
                cur = await conn.execute(
                    "SELECT gt.id, gt.name FROM gate_terminals gt WHERE gt.terminal_type = 'ENTRY' AND gt.facility_id = %s ORDER BY gt.name",
                    (fid,),
                )
            else:
                cur = await conn.execute(
                    "SELECT id, name FROM gate_terminals WHERE terminal_type = 'ENTRY' ORDER BY name"
                )
            terminals = await cur.fetchall()

        return templates.TemplateResponse(
            request=request,
            name="admin/entry.html",
            context={
                "user": user,
                "terminals": terminals,
                "error": error_msg,
                "form_data": {
                    "reservation_id": reservation_id,
                    "license_plate": license_plate,
                },
            },
        )


# ---------------------------------------------------------------------------
# GET /admin/sessions  –  all parking sessions + payments
# ---------------------------------------------------------------------------
@router.get("/sessions", response_class=HTMLResponse)
async def sessions(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        sessions_sql = """
            SELECT
                ps.id,
                ps.status,
                ps.entry_time,
                ps.exit_time,
                ps.amount,
                v.license_plate,
                v.vehicle_type,
                gt_in.name       AS entry_terminal,
                gt_out.name      AS exit_terminal,
                pf.name          AS facility_name,
                sp.spot_number
            FROM parking_sessions ps
            JOIN vehicles          v       ON v.id      = ps.vehicle_id
            JOIN gate_terminals    gt_in   ON gt_in.id  = ps.entry_terminal_id
            LEFT JOIN gate_terminals gt_out ON gt_out.id = ps.exit_terminal_id
            JOIN parking_spots     sp      ON sp.id     = ps.spot_id
            JOIN parking_zones     pz      ON pz.id     = sp.zone_id
            JOIN parking_facilities pf     ON pf.id     = pz.facility_id
        """
        if scoped:
            cur = await conn.execute(sessions_sql + " WHERE pz.facility_id = %s ORDER BY ps.entry_time DESC", (fid,))
        else:
            cur = await conn.execute(sessions_sql + " ORDER BY ps.entry_time DESC")
        all_sessions = await cur.fetchall()

        payments_sql = """
            SELECT
                p.*,
                v.license_plate
            FROM payments p
            JOIN parking_sessions pss ON pss.id = p.session_id
            JOIN parking_spots    sp  ON sp.id  = pss.spot_id
            JOIN parking_zones    pz  ON pz.id  = sp.zone_id
            JOIN vehicles         v   ON v.id   = pss.vehicle_id
        """
        if scoped:
            cur = await conn.execute(payments_sql + " WHERE pz.facility_id = %s ORDER BY p.paid_at DESC", (fid,))
        else:
            cur = await conn.execute(payments_sql + " ORDER BY p.paid_at DESC")
        payments = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/sessions.html",
        context={
            "user": user,
            "sessions": all_sessions,
            "payments": payments,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/exit  –  show exit form
# ---------------------------------------------------------------------------
@router.get("/exit", response_class=HTMLResponse)
async def exit_page(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        if scoped:
            cur = await conn.execute(
                "SELECT gt.id, gt.name FROM gate_terminals gt WHERE gt.terminal_type = 'EXIT' AND gt.facility_id = %s ORDER BY gt.name",
                (fid,),
            )
        else:
            cur = await conn.execute(
                "SELECT id, name FROM gate_terminals WHERE terminal_type = 'EXIT' ORDER BY name"
            )
        terminals = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/exit.html",
        context={
            "user": user,
            "terminals": terminals,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


# ---------------------------------------------------------------------------
# POST /admin/exit  –  record vehicle exit
# ---------------------------------------------------------------------------
@router.post("/exit")
async def process_exit(
    request: Request,
    license_plate: str = Form(...),
    exit_terminal_id: str = Form(...),
):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    license_plate = license_plate.upper().strip()

    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT process_vehicle_exit(%s, %s) AS payment_id",
                (license_plate, exit_terminal_id),
            )
            result = await cur.fetchone()
            payment_id = result["payment_id"]

        return RedirectResponse(
            f"/admin/exit?success=Vehicle+exit+recorded.+Payment+ID%3A+{payment_id}",
            status_code=302,
        )

    except Exception as exc:
        error_msg = str(exc).split("\n")[0]
        scoped, fid = facility_filter(user)
        async with get_db() as conn:
            if scoped:
                cur = await conn.execute(
                    "SELECT gt.id, gt.name FROM gate_terminals gt WHERE gt.terminal_type = 'EXIT' AND gt.facility_id = %s ORDER BY gt.name",
                    (fid,),
                )
            else:
                cur = await conn.execute(
                    "SELECT id, name FROM gate_terminals WHERE terminal_type = 'EXIT' ORDER BY name"
                )
            terminals = await cur.fetchall()

        return templates.TemplateResponse(
            request=request,
            name="admin/exit.html",
            context={
                "user": user,
                "terminals": terminals,
                "error": error_msg,
                "form_data": {"license_plate": license_plate},
            },
        )


# ---------------------------------------------------------------------------
# GET /admin/facilities
# ---------------------------------------------------------------------------
@router.get("/facilities", response_class=HTMLResponse)
async def facilities(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        base_sql = """
            SELECT
                pf.id,
                pf.name,
                pf.address,
                pf.city,
                pf.status,
                COUNT(DISTINCT pz.id)                                            AS zone_count,
                COUNT(ps.id)                                                     AS total_spots,
                SUM(CASE WHEN ps.status = 'AVAILABLE' THEN 1 ELSE 0 END)        AS available_spots,
                SUM(CASE WHEN ps.status = 'OCCUPIED'  THEN 1 ELSE 0 END)        AS occupied_spots
            FROM parking_facilities pf
            LEFT JOIN parking_zones pz ON pz.facility_id = pf.id
            LEFT JOIN parking_spots ps ON ps.zone_id     = pz.id
        """
        if scoped:
            cur = await conn.execute(
                base_sql + " WHERE pf.id = %s GROUP BY pf.id, pf.name, pf.address, pf.city, pf.status ORDER BY pf.name",
                (fid,),
            )
        else:
            cur = await conn.execute(
                base_sql + " GROUP BY pf.id, pf.name, pf.address, pf.city, pf.status ORDER BY pf.name"
            )
        all_facilities = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/facilities.html",
        context={
            "user": user,
            "facilities": all_facilities,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/spots  –  spot occupancy grid
# ---------------------------------------------------------------------------
@router.get("/spots", response_class=HTMLResponse)
async def spots(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        base_sql = """
            SELECT
                pf.name  AS facility_name,
                pz.name  AS zone_name,
                ps.id,
                ps.spot_number,
                ps.vehicle_type,
                ps.status
            FROM parking_spots     ps
            JOIN parking_zones     pz ON pz.id = ps.zone_id
            JOIN parking_facilities pf ON pf.id = pz.facility_id
        """
        if scoped:
            cur = await conn.execute(
                base_sql + " WHERE pz.facility_id = %s ORDER BY pf.name, pz.name, ps.spot_number",
                (fid,),
            )
        else:
            cur = await conn.execute(
                base_sql + " ORDER BY pf.name, pz.name, ps.spot_number"
            )
        all_spots = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/spots.html",
        context={
            "user": user,
            "spots": all_spots,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/reports/occupancy
# ---------------------------------------------------------------------------
@router.get("/reports/occupancy", response_class=HTMLResponse)
async def occupancy_report(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        occupancy_sql = """
            SELECT
                pf.name          AS facility,
                ps.vehicle_type,
                COUNT(*)         AS total_spots,
                SUM(CASE WHEN ps.status = 'OCCUPIED'    THEN 1 ELSE 0 END) AS occupied,
                SUM(CASE WHEN ps.status = 'RESERVED'    THEN 1 ELSE 0 END) AS reserved,
                SUM(CASE WHEN ps.status = 'AVAILABLE'   THEN 1 ELSE 0 END) AS available,
                SUM(CASE WHEN ps.status = 'MAINTENANCE' THEN 1 ELSE 0 END) AS maintenance,
                ROUND(
                    100.0 * SUM(CASE WHEN ps.status IN ('OCCUPIED','RESERVED') THEN 1 ELSE 0 END)
                    / NULLIF(COUNT(*), 0),
                    1
                )                AS occupancy_pct
            FROM parking_spots     ps
            JOIN parking_zones     pz ON pz.id = ps.zone_id
            JOIN parking_facilities pf ON pf.id = pz.facility_id
        """
        if scoped:
            cur = await conn.execute(
                occupancy_sql + " WHERE pz.facility_id = %s GROUP BY pf.id, pf.name, ps.vehicle_type ORDER BY pf.name, ps.vehicle_type",
                (fid,),
            )
        else:
            cur = await conn.execute(
                occupancy_sql + " GROUP BY pf.id, pf.name, ps.vehicle_type ORDER BY pf.name, ps.vehicle_type"
            )
        occupancy = await cur.fetchall()

        revenue_sql = """
            SELECT
                pf.name                      AS facility,
                COALESCE(SUM(p.amount), 0)   AS total_revenue,
                COUNT(p.id)                  AS transactions
            FROM parking_facilities pf
            LEFT JOIN parking_zones    pz  ON pz.facility_id = pf.id
            LEFT JOIN parking_spots    sp  ON sp.zone_id     = pz.id
            LEFT JOIN parking_sessions pss ON pss.spot_id    = sp.id
            LEFT JOIN payments         p   ON p.session_id   = pss.id
        """
        if scoped:
            cur = await conn.execute(
                revenue_sql + " WHERE pf.id = %s GROUP BY pf.id, pf.name",
                (fid,),
            )
        else:
            cur = await conn.execute(
                revenue_sql + " GROUP BY pf.id, pf.name ORDER BY pf.name"
            )
        revenue = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/occupancy.html",
        context={
            "user": user,
            "occupancy": occupancy,
            "revenue": revenue,
        },
    )


# ---------------------------------------------------------------------------
# GET /admin/tariffs  –  list tariffs (scoped for FACILITY_ADMIN)
# ---------------------------------------------------------------------------
@router.get("/tariffs", response_class=HTMLResponse)
async def tariffs_page(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    scoped, fid = facility_filter(user)

    async with get_db() as conn:
        base_sql = """
            SELECT
                t.id,
                t.zone_id,
                t.vehicle_type,
                t.hourly_rate,
                pz.name          AS zone_name,
                pf.name          AS facility_name,
                pf.id            AS facility_id
            FROM tariffs t
            JOIN parking_zones     pz ON pz.id = t.zone_id
            JOIN parking_facilities pf ON pf.id = pz.facility_id
        """
        if scoped:
            cur = await conn.execute(
                base_sql + " WHERE pz.facility_id = %s ORDER BY pf.name, pz.name, t.vehicle_type",
                (fid,),
            )
        else:
            cur = await conn.execute(
                base_sql + " ORDER BY pf.name, pz.name, t.vehicle_type"
            )
        all_tariffs = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/tariffs.html",
        context={
            "user": user,
            "tariffs": all_tariffs,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


# ---------------------------------------------------------------------------
# POST /admin/tariffs/{tariff_id}/update  –  update hourly rate
# ---------------------------------------------------------------------------
@router.post("/tariffs/{tariff_id}/update")
async def update_tariff(
    request: Request,
    tariff_id: str,
    hourly_rate: float = Form(...),
):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    if hourly_rate <= 0:
        return RedirectResponse("/admin/tariffs?error=Hourly+rate+must+be+greater+than+zero.", status_code=302)

    scoped, fid = facility_filter(user)

    try:
        async with get_db() as conn:
            # If scoped, verify the tariff belongs to this facility before updating
            if scoped:
                cur = await conn.execute(
                    """
                    SELECT t.id FROM tariffs t
                    JOIN parking_zones pz ON pz.id = t.zone_id
                    WHERE t.id = %s AND pz.facility_id = %s
                    """,
                    (tariff_id, fid),
                )
                if not await cur.fetchone():
                    return RedirectResponse(
                        "/admin/tariffs?error=Unauthorized+to+edit+this+tariff.",
                        status_code=302,
                    )

            await conn.execute(
                "UPDATE tariffs SET hourly_rate = %s WHERE id = %s",
                (hourly_rate, tariff_id),
            )

        return RedirectResponse("/admin/tariffs?success=Tariff+updated+successfully.", status_code=302)

    except Exception as exc:
        error_msg = str(exc).split("\n")[0]
        return RedirectResponse(f"/admin/tariffs?error={error_msg}", status_code=302)


# ---------------------------------------------------------------------------
# GET /admin/users  –  manage facility admins (SUPER ADMIN ONLY)
# ---------------------------------------------------------------------------
@router.get("/users", response_class=HTMLResponse)
async def users_page(request: Request):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)
    if not is_super_admin(user):
        return RedirectResponse("/admin/dashboard?error=Access+denied.", status_code=302)

    async with get_db() as conn:
        cur = await conn.execute(
            """
            SELECT
                u.id, u.name, u.email, u.role, u.created_at,
                pf.name AS facility_name
            FROM users u
            LEFT JOIN parking_facilities pf ON pf.id = u.facility_id
            WHERE u.role IN ('ADMIN', 'FACILITY_ADMIN')
            ORDER BY u.role, u.name
            """
        )
        admins = await cur.fetchall()

        cur = await conn.execute(
            "SELECT id, name FROM parking_facilities WHERE status = 'ACTIVE' ORDER BY name"
        )
        facilities = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="admin/users.html",
        context={
            "user": user,
            "admins": admins,
            "facilities": facilities,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


# ---------------------------------------------------------------------------
# POST /admin/users  –  create a new FACILITY_ADMIN (SUPER ADMIN ONLY)
# ---------------------------------------------------------------------------
@router.post("/users")
async def create_facility_admin(
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    password: str = Form(...),
    facility_id: str = Form(...),
):
    user = require_admin(request)
    if not user:
        return RedirectResponse("/login", status_code=302)
    if not is_super_admin(user):
        return RedirectResponse("/admin/dashboard", status_code=302)

    if len(password) < 6:
        return RedirectResponse(
            "/admin/users?error=Password+must+be+at+least+6+characters.", status_code=302
        )

    try:
        password_hash = hash_password(password)
        async with get_db() as conn:
            await conn.execute(
                """
                INSERT INTO users (name, email, password_hash, role, facility_id)
                VALUES (%s, %s, %s, 'FACILITY_ADMIN', %s)
                """,
                (name.strip(), email.lower().strip(), password_hash, facility_id),
            )
        return RedirectResponse(
            "/admin/users?success=Facility+admin+created+successfully.", status_code=302
        )

    except Exception as exc:
        error_msg = str(exc).split("\n")[0]
        if "unique" in error_msg.lower() or "duplicate" in error_msg.lower():
            error_msg = "Email already registered."
        return RedirectResponse(f"/admin/users?error={error_msg}", status_code=302)
