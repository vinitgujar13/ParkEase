import bcrypt
import secrets
from datetime import datetime, timezone
from typing import Optional

from fastapi import Request

SESSION_COOKIE = "parking_session"

# In-memory session store (adequate for academic demo)
_sessions: dict[str, dict] = {}


def hash_password(password: str) -> str:
    """Hash a plaintext password using bcrypt."""
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    """Verify a plaintext password against a bcrypt hash."""
    return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))


def create_session(
    user_id: str,
    email: str,
    name: str,
    role: str,
    facility_id: Optional[str] = None,
) -> str:
    """Create a new server-side session and return the token.

    For FACILITY_ADMIN users ``facility_id`` should be set so that
    admin routes can scope queries to only that facility.
    """
    token = secrets.token_urlsafe(32)
    _sessions[token] = {
        "user_id": user_id,
        "email": email,
        "name": name,
        "role": role,
        "facility_id": facility_id,  # None for ADMIN / CUSTOMER
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    return token


def get_session(token: str) -> Optional[dict]:
    """Look up a session by token."""
    return _sessions.get(token)


def delete_session(token: str) -> None:
    """Remove a session."""
    _sessions.pop(token, None)


def get_current_user(request: Request) -> Optional[dict]:
    """Return the session user dict for the current request, or None."""
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None
    return get_session(token)
