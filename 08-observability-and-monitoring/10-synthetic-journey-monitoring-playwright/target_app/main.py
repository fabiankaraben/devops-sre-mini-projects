"""CloudStore Target E-Commerce Application with Built-in Chaos Simulation."""

import os
import random
import time
import uuid
from typing import Dict, List, Optional
from fastapi import FastAPI, Form, HTTPException, Request, Response, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

app = FastAPI(title="CloudStore E-Commerce", version="1.0.0")

# Setup directories
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

# In-memory product catalog
PRODUCTS = [
    {
        "id": "prod-101",
        "name": "Cloud Observability Handbook",
        "category": "Documentation & Books",
        "price": 49.99,
        "description": "Comprehensive guide to OpenTelemetry, Prometheus, and distributed tracing architectures.",
    },
    {
        "id": "prod-102",
        "name": "Kubernetes Cluster Key Fob",
        "category": "Hardware & Security",
        "price": 19.99,
        "description": "Encrypted hardware token for SRE on-call authentication and cluster emergency access.",
    },
    {
        "id": "prod-103",
        "name": "SRE On-Call Survival Hoodie",
        "category": "Apparel & Gear",
        "price": 64.50,
        "description": "Premium ultra-comfortable fleece hoodie with terminal cheat sheets printed inside pockets.",
    },
]

PRODUCTS_BY_ID = {p["id"]: p for p in PRODUCTS}

# In-memory sessions storage: session_id -> {"user": email, "cart": {product_id: qty}}
SESSIONS: Dict[str, dict] = {}

# Chaos engineering state variables
CHAOS_STATE = {
    "latency_seconds": 0.0,
    "latency_step": "none",
    "fail_checkout": False,
    "failure_message": "Database connection pool exhausted: synthetic chaos triggered.",
}


def get_or_create_session(request: Request) -> (str, dict):
    session_id = request.cookies.get("cloudstore_session")
    if not session_id or session_id not in SESSIONS:
        session_id = str(uuid.uuid4())
        SESSIONS[session_id] = {"user": None, "cart": {}}
    return session_id, SESSIONS[session_id]


def get_cart_items_and_total(session: dict):
    cart = session.get("cart", {})
    items = []
    total = 0.0
    count = 0
    for pid, qty in cart.items():
        if pid in PRODUCTS_BY_ID:
            prod = PRODUCTS_BY_ID[pid]
            items.append({**prod, "quantity": qty})
            total += prod["price"] * qty
            count += qty
    return items, total, count


# ------------------------------------------------------------------------------
# Frontend Page Routes
# ------------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def home_page(request: Request):
    """Render catalog homepage."""
    session_id, session = get_or_create_session(request)
    _, _, cart_count = get_cart_items_and_total(session)
    response = templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "products": PRODUCTS,
            "cart_count": cart_count,
            "user": session.get("user"),
        },
    )
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, error: Optional[str] = None):
    """Render login page."""
    session_id, session = get_or_create_session(request)
    _, _, cart_count = get_cart_items_and_total(session)
    response = templates.TemplateResponse(
        "login.html",
        {"request": request, "cart_count": cart_count, "error": error},
    )
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.get("/cart", response_class=HTMLResponse)
async def cart_page(request: Request):
    """Render shopping cart view."""
    session_id, session = get_or_create_session(request)
    cart_items, total_amount, cart_count = get_cart_items_and_total(session)
    response = templates.TemplateResponse(
        "cart.html",
        {
            "request": request,
            "cart_items": cart_items,
            "total_amount": total_amount,
            "cart_count": cart_count,
            "user": session.get("user"),
        },
    )
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.get("/checkout", response_class=HTMLResponse)
async def checkout_page(request: Request, error: Optional[str] = None):
    """Render checkout form."""
    session_id, session = get_or_create_session(request)
    cart_items, total_amount, cart_count = get_cart_items_and_total(session)

    # Auto-add default item if cart is empty for testing convenience
    if not cart_items:
        session["cart"]["prod-101"] = 1
        cart_items, total_amount, cart_count = get_cart_items_and_total(session)

    response = templates.TemplateResponse(
        "checkout.html",
        {
            "request": request,
            "cart_items": cart_items,
            "total_amount": total_amount,
            "cart_count": cart_count,
            "user": session.get("user"),
            "error": error,
        },
    )
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.get("/order-confirmation", response_class=HTMLResponse)
async def confirmation_page(request: Request, order_id: str = "ORD-2026-DEMO"):
    """Render order confirmation."""
    return templates.TemplateResponse(
        "confirmation.html",
        {"request": request, "order_id": order_id},
    )


# ------------------------------------------------------------------------------
# Action APIs
# ------------------------------------------------------------------------------
@app.post("/api/login")
async def api_login(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
):
    """Authenticate synthetic user."""
    session_id, session = get_or_create_session(request)

    # Simulate realistic authentication validation
    if not email or "@" not in email:
        return RedirectResponse(url="/login?error=Invalid+email+format", status_code=status.HTTP_303_SEE_OTHER)

    session["user"] = {"email": email}
    response = RedirectResponse(url="/cart", status_code=status.HTTP_303_SEE_OTHER)
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.get("/api/logout")
async def api_logout(request: Request):
    """Logout current user."""
    session_id, session = get_or_create_session(request)
    session["user"] = None
    response = RedirectResponse(url="/", status_code=status.HTTP_303_SEE_OTHER)
    return response


@app.post("/api/cart/add")
async def api_cart_add(request: Request, product_id: str = Form(...)):
    """Add product to shopping cart."""
    session_id, session = get_or_create_session(request)
    if product_id in PRODUCTS_BY_ID:
        session["cart"][product_id] = session["cart"].get(product_id, 0) + 1

    response = RedirectResponse(url="/cart", status_code=status.HTTP_303_SEE_OTHER)
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


@app.post("/api/checkout")
async def api_checkout(
    request: Request,
    full_name: str = Form(...),
    address: str = Form(...),
    card_number: str = Form(...),
    exp_date: str = Form(...),
    cvv: str = Form(...),
):
    """Process checkout submission and simulate chaos scenarios."""
    session_id, session = get_or_create_session(request)

    # 1. Apply artificial latency if chaos is enabled for checkout
    if CHAOS_STATE["latency_seconds"] > 0:
        time.sleep(CHAOS_STATE["latency_seconds"])

    # 2. Trigger intentional failure if chaos failure toggle is active
    if CHAOS_STATE["fail_checkout"]:
        # Return 500 status to force Playwright step failure and trigger diagnostic screenshot
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=CHAOS_STATE["failure_message"],
        )

    # 3. Successful order processing
    order_ref = f"ORD-2026-{uuid.uuid4().hex[:8].upper()}"
    session["cart"] = {}  # Clear cart

    response = RedirectResponse(
        url=f"/order-confirmation?order_id={order_ref}",
        status_code=status.HTTP_303_SEE_OTHER,
    )
    response.set_cookie("cloudstore_session", session_id, httponly=True)
    return response


# ------------------------------------------------------------------------------
# System & Chaos Control Endpoints
# ------------------------------------------------------------------------------
@app.get("/healthz", tags=["System"])
async def healthz():
    return {"status": "healthy", "service": "target-store", "timestamp": time.time()}


@app.post("/api/chaos/latency", tags=["Chaos Engineering"])
async def set_chaos_latency(delay: float = 2.5, step: str = "checkout"):
    """Inject artificial delay on checkout requests."""
    CHAOS_STATE["latency_seconds"] = max(0.0, delay)
    CHAOS_STATE["latency_step"] = step
    return {"status": "chaos_latency_active", "delay_seconds": CHAOS_STATE["latency_seconds"], "step": step}


@app.post("/api/chaos/fail-checkout", tags=["Chaos Engineering"])
async def trigger_chaos_failure():
    """Trigger intentional HTTP 500 failure on checkout step."""
    CHAOS_STATE["fail_checkout"] = True
    return {"status": "chaos_failure_active", "target": "checkout"}


@app.post("/api/chaos/reset", tags=["Chaos Engineering"])
async def reset_chaos():
    """Reset all chaos variables to normal operation."""
    CHAOS_STATE["latency_seconds"] = 0.0
    CHAOS_STATE["latency_step"] = "none"
    CHAOS_STATE["fail_checkout"] = False
    return {"status": "chaos_reset_to_normal", "chaos_state": CHAOS_STATE}


@app.get("/api/chaos/status", tags=["Chaos Engineering"])
async def get_chaos_status():
    """Get current chaos state."""
    return CHAOS_STATE
