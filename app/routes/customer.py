from fastapi import APIRouter, Request, Form, Depends
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from app.db import get_db
from app.auth import get_current_user, SESSION_COOKIE
from typing import Optional
from urllib.parse import quote_plus
import psycopg

router = APIRouter(tags=["customer"])
templates = Jinja2Templates(directory="app/templates")


def get_user(request: Request) -> Optional[dict]:
    return get_current_user(request)


def require_customer(request: Request) -> dict:
    user = get_current_user(request)
    if not user:
        raise Exception("redirect:/login")
    if user["role"] != "CUSTOMER":
        raise Exception("redirect:/login")
    return user


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request):
    user = get_current_user(request)
    if not user:
        return RedirectResponse("/login", status_code=302)
    if user["role"] != "CUSTOMER":
        return RedirectResponse("/admin/dashboard", status_code=302)

    async with get_db() as conn:
        # Count vehicles
        cur = await conn.execute(
            "SELECT COUNT(*) as cnt FROM vehicles WHERE user_id = %s",
            (user["user_id"],)
        )
        vehicles_count = (await cur.fetchone())["cnt"]

        # Active reservation
        cur = await conn.execute(
            """SELECT r.id, r.status, r.start_time, pf.name as facility_name,
                      ps.spot_number, v.license_plate, v.vehicle_type
               FROM reservations r
               JOIN vehicles v ON v.id = r.vehicle_id
               JOIN parking_spots ps ON ps.id = r.spot_id
               JOIN parking_zones pz ON pz.id = ps.zone_id
               JOIN parking_facilities pf ON pf.id = pz.facility_id
               WHERE r.user_id = %s AND r.status IN ('CONFIRMED', 'ACTIVE')
               ORDER BY r.created_at DESC LIMIT 1""",
            (user["user_id"],)
        )
        active_reservation = await cur.fetchone()

        # Recent reservations
        cur = await conn.execute(
            """SELECT r.id, r.status, r.start_time, r.created_at,
                      pf.name as facility_name, ps.spot_number, v.license_plate
               FROM reservations r
               JOIN vehicles v ON v.id = r.vehicle_id
               JOIN parking_spots ps ON ps.id = r.spot_id
               JOIN parking_zones pz ON pz.id = ps.zone_id
               JOIN parking_facilities pf ON pf.id = pz.facility_id
               WHERE r.user_id = %s
               ORDER BY r.created_at DESC LIMIT 5""",
            (user["user_id"],)
        )
        recent_reservations = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="customer/dashboard.html",
        context={
            "user": user,
            "vehicles_count": vehicles_count,
            "active_reservation": active_reservation,
            "recent_reservations": recent_reservations,
        },
    )


@router.get("/vehicles", response_class=HTMLResponse)
async def vehicles_page(request: Request):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    async with get_db() as conn:
        cur = await conn.execute(
            """SELECT id, license_plate, vehicle_type, model, color, created_at
               FROM vehicles WHERE user_id = %s ORDER BY created_at DESC""",
            (user["user_id"],)
        )
        vehicles = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="customer/vehicles.html",
        context={
            "user": user,
            "vehicles": vehicles,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


@router.post("/vehicles")
async def add_vehicle(
    request: Request,
    license_plate: str = Form(...),
    vehicle_type: str = Form(...),
    model: str = Form(...),
    color: str = Form(...)
):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    license_plate = license_plate.upper().strip()

    try:
        async with get_db() as conn:
            await conn.execute(
                """INSERT INTO vehicles (user_id, license_plate, vehicle_type, model, color)
                   VALUES (%s, %s, %s, %s, %s)""",
                (user["user_id"], license_plate, vehicle_type, model.strip(), color.strip())
            )
        return RedirectResponse("/customer/vehicles?success=Vehicle+registered+successfully", status_code=302)
    except psycopg.errors.UniqueViolation:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT id, license_plate, vehicle_type, model, color, created_at FROM vehicles WHERE user_id = %s ORDER BY created_at DESC",
                (user["user_id"],)
            )
            vehicles = await cur.fetchall()
        return templates.TemplateResponse(
            request=request,
            name="customer/vehicles.html",
            context={
                "user": user,
                "vehicles": vehicles,
                "error": "License plate already registered.",
            },
        )
    except Exception as e:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT id, license_plate, vehicle_type, model, color, created_at FROM vehicles WHERE user_id = %s ORDER BY created_at DESC",
                (user["user_id"],)
            )
            vehicles = await cur.fetchall()
        return templates.TemplateResponse(
            request=request,
            name="customer/vehicles.html",
            context={
                "user": user,
                "vehicles": vehicles,
                "error": f"Error: {str(e)}",
            },
        )


@router.get("/reserve", response_class=HTMLResponse)
async def reserve_page(request: Request):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    error = request.query_params.get("error")

    async with get_db() as conn:
        # Check for active reservation
        cur = await conn.execute(
            "SELECT id FROM reservations WHERE user_id = %s AND status IN ('CONFIRMED', 'ACTIVE')",
            (user["user_id"],)
        )
        active_res = await cur.fetchone()

        # Get customer vehicles
        cur = await conn.execute(
            "SELECT id, license_plate, vehicle_type, model FROM vehicles WHERE user_id = %s ORDER BY license_plate",
            (user["user_id"],)
        )
        vehicles = await cur.fetchall()

        # Get facilities with availability broken down by vehicle type
        cur = await conn.execute(
            """SELECT
                pf.id, pf.name, pf.address, pf.city,
                COUNT(CASE WHEN ps.vehicle_type = 'TWO_WHEELER' AND ps.status = 'AVAILABLE' THEN 1 END) as tw_available,
                COUNT(CASE WHEN ps.vehicle_type = 'FOUR_WHEELER' AND ps.status = 'AVAILABLE' THEN 1 END) as fw_available,
                COUNT(ps.id) as total_spots
               FROM parking_facilities pf
               LEFT JOIN parking_zones pz ON pz.facility_id = pf.id
               LEFT JOIN parking_spots ps ON ps.zone_id = pz.id
               WHERE pf.status = 'ACTIVE'
               GROUP BY pf.id, pf.name, pf.address, pf.city
               ORDER BY pf.name"""
        )
        facilities = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="customer/reserve.html",
        context={
            "user": user,
            "vehicles": vehicles,
            "facilities": facilities,
            "active_reservation": active_res,
            "error": error,
        },
    )


@router.post("/reserve")
async def create_reservation(
    request: Request,
    vehicle_id: str = Form(...),
    facility_id: str = Form(...)
):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT create_reservation(%s, %s, %s, NOW()) AS reservation_id",
                (user["user_id"], vehicle_id, facility_id)
            )
            result = await cur.fetchone()
            reservation_id = result["reservation_id"]
        return RedirectResponse(
            "/customer/reservations?success=Reservation+created+successfully",
            status_code=302
        )
    except psycopg.errors.RaiseException as e:
        error_msg = str(e).split('\n')[0]
        return RedirectResponse(
            f"/customer/reserve?error={quote_plus(error_msg)}",
            status_code=302
        )
    except Exception as e:
        error_msg = str(e).split('\n')[0]
        return RedirectResponse(
            f"/customer/reserve?error={quote_plus(error_msg)}",
            status_code=302
        )


@router.get("/reservations", response_class=HTMLResponse)
async def reservations_page(request: Request):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    async with get_db() as conn:
        cur = await conn.execute(
            """SELECT
                r.id, r.status, r.start_time, r.created_at,
                pf.name as facility_name, pf.address,
                pz.name as zone_name,
                ps.spot_number, ps.vehicle_type as spot_type,
                v.license_plate, v.vehicle_type, v.model
               FROM reservations r
               JOIN vehicles v ON v.id = r.vehicle_id
               JOIN parking_spots ps ON ps.id = r.spot_id
               JOIN parking_zones pz ON pz.id = ps.zone_id
               JOIN parking_facilities pf ON pf.id = pz.facility_id
               WHERE r.user_id = %s
               ORDER BY r.created_at DESC""",
            (user["user_id"],)
        )
        reservations = await cur.fetchall()

    return templates.TemplateResponse(
        request=request,
        name="customer/reservations.html",
        context={
            "user": user,
            "reservations": reservations,
            "success": request.query_params.get("success"),
            "error": request.query_params.get("error"),
        },
    )


@router.post("/reservations/{reservation_id}/cancel")
async def cancel_reservation(request: Request, reservation_id: str):
    user = get_current_user(request)
    if not user or user["role"] != "CUSTOMER":
        return RedirectResponse("/login", status_code=302)

    try:
        async with get_db() as conn:
            cur = await conn.execute(
                "SELECT cancel_reservation(%s, %s) AS success",
                (reservation_id, user["user_id"])
            )
            result = await cur.fetchone()
        return RedirectResponse(
            "/customer/reservations?success=Reservation+cancelled+successfully",
            status_code=302
        )
    except Exception as e:
        error_msg = str(e).split('\n')[0]
        return RedirectResponse(
            f"/customer/reservations?error={quote_plus(error_msg)}",
            status_code=302
        )
