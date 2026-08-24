#!/usr/bin/env python3
"""
app/main.py - Dynamic Multi-Version Web API for Schema Refactoring

Simulates a live application undergoing zero-downtime database schema refactoring.
Supports V1 mode (legacy full_name queries), V2 mode (refactored first_name / last_name queries),
and live dynamic cutover without application restarts.
"""

import os
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
import psycopg2
from psycopg2.pool import SimpleConnectionPool

# Configuration
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_USER = os.getenv("POSTGRES_USER", "postgres")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "postgres")
POSTGRES_DB = os.getenv("POSTGRES_DB", "users_db")

pool: Optional[SimpleConnectionPool] = None
APP_VERSION = os.getenv("INITIAL_APP_VERSION", "v1")


def get_db_connection():
    global pool
    if pool is None:
        pool = SimpleConnectionPool(
            minconn=2,
            maxconn=30,
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD,
            dbname=POSTGRES_DB
        )
    return pool.getconn()


def release_db_connection(conn):
    if pool and conn:
        pool.putconn(conn)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize connection pool
    retries = 15
    while retries > 0:
        try:
            conn = get_db_connection()
            release_db_connection(conn)
            break
        except Exception:
            time.sleep(1)
            retries -= 1
    yield
    if pool:
        pool.closeall()


app = FastAPI(title="Zero-Downtime Schema Refactoring Demo API", lifespan=lifespan)


class UserCreateV1(BaseModel):
    full_name: str
    email: str


class UserCreateV2(BaseModel):
    first_name: str
    last_name: str
    email: str


class UserResponse(BaseModel):
    id: int
    full_name: Optional[str] = None
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: str


@app.get("/health")
def health_check():
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1;")
        return {"status": "ok", "app_version": APP_VERSION, "database": "connected"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        release_db_connection(conn)


@app.get("/version")
def get_version():
    return {"version": APP_VERSION}


@app.post("/version/{version}")
def switch_version(version: str):
    global APP_VERSION
    if version not in ["v1", "v2"]:
        raise HTTPException(status_code=400, detail="Invalid version. Must be 'v1' or 'v2'.")
    APP_VERSION = version
    return {"message": f"App cutover completed. Active mode: {APP_VERSION}", "version": APP_VERSION}


@app.get("/schema")
def inspect_schema():
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("""
                SELECT column_name, is_nullable, data_type 
                FROM information_schema.columns 
                WHERE table_name = 'users' 
                ORDER BY ordinal_position;
            """)
            cols = [{"column": r[0], "nullable": r[1], "type": r[2]} for r in cur.fetchall()]
        col_names = [c["column"] for c in cols]
        phase = "V1 Baseline"
        if "first_name" in col_names and "full_name" in col_names:
            phase = "Phase 1 / 2 (Expanded / Dual-State)"
        elif "first_name" in col_names and "full_name" not in col_names:
            phase = "Phase 3 (Contracted)"
        return {"phase": phase, "columns": cols}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        release_db_connection(conn)


@app.get("/users")
def list_users(limit: int = 50):
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            # Dynamically inspect available columns
            cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name = 'users';")
            cols = {r[0] for r in cur.fetchall()}
            
            if "full_name" in cols and "first_name" in cols:
                cur.execute("SELECT id, full_name, first_name, last_name, email FROM users ORDER BY id DESC LIMIT %s;", (limit,))
                rows = cur.fetchall()
                return [{"id": r[0], "full_name": r[1], "first_name": r[2], "last_name": r[3], "email": r[4]} for r in rows]
            elif "first_name" in cols:
                cur.execute("SELECT id, first_name, last_name, email FROM users ORDER BY id DESC LIMIT %s;", (limit,))
                rows = cur.fetchall()
                return [{"id": r[0], "full_name": f"{r[1]} {r[2]}".strip(), "first_name": r[1], "last_name": r[2], "email": r[3]} for r in rows]
            else:
                cur.execute("SELECT id, full_name, email FROM users ORDER BY id DESC LIMIT %s;", (limit,))
                rows = cur.fetchall()
                return [{"id": r[0], "full_name": r[1], "email": r[2]} for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        release_db_connection(conn)


@app.post("/users", status_code=status.HTTP_201_CREATED)
def create_user(payload: dict):
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            email = payload.get("email")
            if not email:
                raise HTTPException(status_code=422, detail="Missing required field 'email'.")

            # Check if app is in V2 mode or payload explicitly sends first_name / last_name
            if APP_VERSION == "v2" or ("first_name" in payload and "last_name" in payload):
                first_name = payload.get("first_name", "")
                last_name = payload.get("last_name", "")
                cur.execute("""
                    INSERT INTO users (first_name, last_name, email)
                    VALUES (%s, %s, %s)
                    RETURNING id;
                """, (first_name, last_name, email))
                new_id = cur.fetchone()[0]
                conn.commit()
                return {
                    "id": new_id,
                    "first_name": first_name,
                    "last_name": last_name,
                    "full_name": f"{first_name} {last_name}".strip(),
                    "email": email,
                    "api_mode": "v2"
                }
            else:
                # V1 Mode
                full_name = payload.get("full_name", "")
                cur.execute("""
                    INSERT INTO users (full_name, email)
                    VALUES (%s, %s)
                    RETURNING id;
                """, (full_name, email))
                new_id = cur.fetchone()[0]
                conn.commit()
                return {
                    "id": new_id,
                    "full_name": full_name,
                    "email": email,
                    "api_mode": "v1"
                }
    except Exception as e:
        if conn:
            conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        release_db_connection(conn)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
