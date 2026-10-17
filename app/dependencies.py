from typing import Optional

from fastapi import Request, HTTPException, status

from app.auth import get_current_user


def get_user_from_session(request: Request) -> Optional[dict]:
    """Returns the current user dict or None."""
    return get_current_user(request)


def require_login(request: Request) -> dict:
    """FastAPI dependency: requires any authenticated user."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_303_SEE_OTHER,
            headers={"Location": "/login"},
        )
    return user


def require_admin_role(request: Request) -> dict:
    """FastAPI dependency: requires the ADMIN role."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_303_SEE_OTHER,
            headers={"Location": "/login"},
        )
    if user["role"] != "ADMIN":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required.",
        )
    return user


def require_customer_role(request: Request) -> dict:
    """FastAPI dependency: requires the CUSTOMER role."""
    user = get_current_user(request)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_303_SEE_OTHER,
            headers={"Location": "/login"},
        )
    if user["role"] != "CUSTOMER":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Customer access required.",
        )
    return user
