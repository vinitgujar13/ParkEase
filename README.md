# ParkEase: Vehicle Parking Management System

A robust, production-grade, and complete mini-project built with **FastAPI**, **PostgreSQL**, **psycopg 3**, **Jinja2 templates**, and **Bootstrap 5**. Designed specifically for academic demonstrations, viva evaluations, and technical interviews.

---

## 1. Architecture & Design Principles

Unlike typical web applications that place business logic exclusively in application code, **ParkEase enforces core business rules, transactional safety, spot locking, fee calculation, and audit logging directly within PostgreSQL** via PL/pgSQL functions and triggers. FastAPI acts as an asynchronous web gateway, translating HTTP requests into stored function invocations and rendering server-side HTML responses.

### Key Architectural Highlights
- **Engine**: PostgreSQL 14+ with `pgcrypto` extension for UUID primary keys (`gen_random_uuid()`) and Blowfish password hashing (`crypt()`).
- **Database Driver**: `psycopg 3` with `AsyncConnectionPool` and `dict_row` row factory for native async, high-concurrency database I/O.
- **Concurrency & Locking**: Spot allocation uses `SELECT ... FOR UPDATE SKIP LOCKED` inside a PL/pgSQL transaction to prevent race conditions during simultaneous customer bookings.
- **Role-Based Access Control (RBAC)**: Secure cookie-based server sessions protecting `/customer/*` and `/admin/*` route trees.
- **No SPA/React**: 100% server-rendered Jinja2 HTML with Bootstrap 5 CDN and custom responsive CSS.
- **Simulation Mode**: Real payment gateways are excluded; a verified `SIMULATED` payment record with a unique transaction reference (`PAY-XXXXXXXX`) is automatically generated upon vehicle exit.

---

## 2. Prerequisites & Environment Setup

### Prerequisites
- Python 3.10+
- PostgreSQL 14+ (or Docker / Docker Compose)

### Environment Variables
Copy `.env.example` to `.env`:
```bash
cp .env.example .env
```

Default configuration in `.env`:
```env
# PostgreSQL connection string
DATABASE_URL=postgresql://parking_user:parking_pass@localhost:5432/parking_db

# Application settings
APP_SECRET_KEY=dev-secret-key-parkease-2024
APP_HOST=0.0.0.0
APP_PORT=8000
APP_DEBUG=true
```

---

## 3. Database Initialization & SQL Execution Order

### Option A: Using Docker Compose (Fastest & Zero Setup)
Run the automated PostgreSQL container with schema and seed data loaded on initialization:
```bash
docker compose up -d
```
*(Wait 5 seconds for PostgreSQL to initialize and load all scripts).*

### Option B: Local PostgreSQL Installation
1. Create the database user and database:
```sql
-- Run as postgres superuser in psql:
CREATE USER parking_user WITH PASSWORD 'parking_pass';
CREATE DATABASE parking_db OWNER parking_user;
GRANT ALL PRIVILEGES ON DATABASE parking_db TO parking_user;
```

2. Execute SQL files **in exact numerical order**:
```bash
psql -U parking_user -d parking_db -f sql/01_schema.sql
psql -U parking_user -d parking_db -f sql/02_functions_procedures.sql
psql -U parking_user -d parking_db -f sql/03_triggers.sql
psql -U parking_user -d parking_db -f sql/04_seed.sql
```

3. (Optional) Run demo verification queries:
```bash
psql -U parking_user -d parking_db -f sql/05_demo_queries.sql
```

---

## 4. Starting the Application

### Option A: Using the Startup Script
```bash
chmod +x run.sh
./run.sh
```

### Option B: Manual Setup
```bash
# 1. Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate

# 2. Install dependencies
pip install -r requirements.txt

# 3. Start Uvicorn server
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

The web application is now live at: **http://localhost:8000**

---

## 5. Demo Login Credentials

| Role | Email Address | Plaintext Password | Seed Profile Details |
|---|---|---|---|
| **ADMIN** | `admin@parking.local` | `Admin@123` | Master Parking Administrator |
| **CUSTOMER** | `demo@parking.local` | `Customer@123` | Pre-registered with 2 vehicles (`KA01AB1234`, `KA02CD5678`) |
| **CUSTOMER** | `customer@parking.local`| `Customer@123` | Fresh customer account |

---

## 6. Complete Academic Demonstration Flow (Step-by-Step)

This 5-step walkthrough demonstrates every constraint, function, trigger, and screen in the application.

```
+---------------------------------------------------------------------------------------------+
|                                    DEMONSTRATION TIMELINE                                   |
|                                                                                             |
| [1. Customer Booking] ---> [2. Spot Locked] ---> [3. Admin Entry] ---> [4. Active Session]  |
|                                                                                 |           |
| [6. Payment & Audit]  <--- [5. Spot Released] <--- [4. Admin Exit & Fee] <------+           |
+---------------------------------------------------------------------------------------------+
```

### Step 1: Customer Login & Vehicle Registration
1. Navigate to `http://localhost:8000/login`.
2. Login with Demo Customer: `demo@parking.local` / `Customer@123`.
3. You will be redirected to `/customer/dashboard`.
4. Click **My Vehicles** (`/customer/vehicles`). Observe the two pre-seeded vehicles:
   - `KA01AB1234` (`TWO_WHEELER`, Honda Activa, Red)
   - `KA02CD5678` (`FOUR_WHEELER`, Maruti Swift, White)
5. Register a new vehicle (e.g. `MH12EF9999`, `FOUR_WHEELER`, Hyundai i20, Blue) to demonstrate unique constraint checks and form handling.

### Step 2: Spot Reservation & Automatic Assignment
1. Go to **Reserve a Spot** (`/customer/reserve`).
2. Notice the real-time availability cards displaying available two-wheeler and four-wheeler bays per facility.
3. Select vehicle `KA01AB1234` (Two-Wheeler) and facility **Central Park Parking**.
4. Click **Confirm Reservation**.
5. The PL/pgSQL function `create_reservation()` executes:
   - Locks the lowest-numbered compatible available spot (`Spot #1` in `Zone A`) using `FOR UPDATE SKIP LOCKED`.
   - Inserts the reservation with status `CONFIRMED`.
   - Fires trigger `trg_set_spot_reserved`, changing spot status from `AVAILABLE` to `RESERVED`.
   - Fires trigger `trg_audit_reservations`, writing to `audit_logs`.
6. You are redirected to `/customer/reservations`. Note the generated **Reservation UUID** (e.g., `550e8400...`). **Copy this ID for Step 3.**
7. *Constraint Demonstration*: Try making another reservation immediately. The database rejects it: *"Customer already has an active reservation"*.

### Step 3: Admin Vehicle Entry
1. Open an incognito browser window or logout and go to `http://localhost:8000/login`.
2. Login with Admin: `admin@parking.local` / `Admin@123`.
3. On the **Admin Dashboard** (`/admin/dashboard`), observe:
   - Reserved spots counter increased by 1.
   - Confirmed reservations counter increased by 1.
4. Go to **Reservations** (`/admin/reservations`) to view the pending booking.
5. Go to **Record Entry** (`/admin/entry`):
   - Paste the **Reservation ID**.
   - Enter License Plate: `KA01AB1234`.
   - Select Entry Gate: `Central Park - Entry Gate A`.
   - Click **Verify & Record Entry**.
6. The PL/pgSQL function `process_vehicle_entry()` executes:
   - Verifies the reservation is `CONFIRMED` and within the 60-minute grace window.
   - Validates that the plate matches the reserved vehicle.
   - Validates that the terminal is an `ENTRY` gate for that specific facility.
   - Inserts row into `parking_sessions` with status `ACTIVE`.
   - Transitions reservation status to `ACTIVE`.
   - Fires trigger `trg_set_spot_occupied`, transitioning spot to `OCCUPIED`.
   - Writes to `audit_logs`.

### Step 4: Admin Vehicle Exit & Automated Fee Calculation
1. From the Admin portal, go to **Record Exit** (`/admin/exit`):
   - Enter License Plate: `KA01AB1234`.
   - Select Exit Gate: `Central Park - Exit Gate A`.
   - Click **Calculate Fee, Record Exit & Payment**.
2. The PL/pgSQL function `process_vehicle_exit()` executes:
   - Finds the active session for `KA01AB1234`.
   - Calls `calculate_parking_fee()`: determines duration, applies minimum 1-hour charge, and multiplies by the Zone A tariff (₹20.00/hr for Two-Wheelers).
   - Marks the parking session as `COMPLETED` with calculated fee (₹20.00).
   - Marks the reservation as `COMPLETED`.
   - Marks the parking spot as `AVAILABLE` (spot released).
   - Generates reference number `PAY-XXXXXXXX` and inserts simulated payment with status `PAID`.
   - Fires payment validation trigger `trg_validate_payment_before_insert`.
   - Writes to `audit_logs`.

### Step 5: pgAdmin / psql Verification
Run the following SQL queries to demonstrate the transactional integrity:
```sql
-- 1. Check completed session and fee
SELECT id, vehicle_id, entry_time, exit_time, amount, status 
FROM parking_sessions WHERE status = 'COMPLETED';

-- 2. Check generated payment
SELECT reference_number, amount, payment_method, status, paid_at 
FROM payments;

-- 3. Verify spot was released back to AVAILABLE
SELECT spot_number, vehicle_type, status 
FROM parking_spots WHERE status = 'AVAILABLE' ORDER BY spot_number;

-- 4. Review immutable audit logs
SELECT table_name, operation, record_id, details, created_at 
FROM audit_logs ORDER BY created_at DESC LIMIT 10;
```

---

## 7. Deep-Dive: Database Functions, Triggers & Constraints

### 7.1 PL/pgSQL Stored Functions

#### Why Functions Instead of Procedures?
In PostgreSQL, standard `PROCEDURE` calls executed via `CALL` cannot directly return scalar values or single-row result sets to client drivers like `psycopg 3` without `INOUT` parameters. In contrast, `FUNCTION` calls invoked via `SELECT function_name(...)` seamlessly return scalar types (`UUID`, `NUMERIC`, `BOOLEAN`) directly into FastAPI cursors, guaranteeing atomic transaction boundaries while preserving clean return values.

1. **`calculate_parking_fee(p_session_id UUID, p_exit_at TIMESTAMPTZ)` -> `NUMERIC`**
   - Retrieves `entry_time`, spot's `zone_id`, and vehicle's `vehicle_type`.
   - Looks up the applicable `hourly_rate` from `tariffs`.
   - Computes elapsed duration in hours: `EXTRACT(EPOCH FROM (exit_at - entry_time)) / 3600.0`.
   - Enforces business rules: rounds up to the next full hour (`CEIL`) with a minimum charge of 1 hour (`GREATEST(1, CEIL(...))`).
   - Returns fee as `NUMERIC(10,2)`.

2. **`create_reservation(p_customer_id UUID, p_vehicle_id UUID, p_facility_id UUID, p_start_at TIMESTAMPTZ)` -> `UUID`**
   - Verifies vehicle ownership: `vehicles.user_id = p_customer_id`.
   - Enforces singular active booking constraint: rejects if customer already has a `CONFIRMED` or `ACTIVE` reservation, or an `ACTIVE` session.
   - Enforces singular vehicle constraint: checks partial index invariants.
   - Concurrency lock: executes `SELECT ps.id FROM parking_spots ps ... WHERE ps.status = 'AVAILABLE' ORDER BY ps.spot_number ASC LIMIT 1 FOR UPDATE SKIP LOCKED`.
   - Atomically inserts the reservation and returns the newly generated `reservation_id`.

3. **`process_vehicle_entry(p_reservation_id UUID, p_license_plate TEXT, p_entry_terminal_id UUID)` -> `UUID`**
   - Verifies reservation exists and status is `CONFIRMED`.
   - Enforces 60-minute grace window: if `NOW() > start_time + 60 minutes`, automatically sets reservation to `EXPIRED`, frees spot, and raises `RESERVATION_EXPIRED`.
   - Validates license plate against the reserved vehicle.
   - Validates that `p_entry_terminal_id` is of type `ENTRY` and belongs to the spot's facility.
   - Inserts active `parking_sessions` record and updates reservation to `ACTIVE`.

4. **`process_vehicle_exit(p_license_plate TEXT, p_exit_terminal_id UUID)` -> `UUID`**
   - Finds the `ACTIVE` session associated with the vehicle plate.
   - Verifies terminal is of type `EXIT` and belongs to the correct facility.
   - Calculates fee using `calculate_parking_fee()`.
   - Updates session to `COMPLETED` and reservation to `COMPLETED`.
   - Frees spot back to `AVAILABLE`.
   - Generates reference number `PAY-XXXXXXXX` and inserts row into `payments` table with status `PAID`.

5. **`cancel_reservation(p_reservation_id UUID, p_customer_id UUID)` -> `BOOLEAN`**
   - Validates that the reservation belongs to `p_customer_id`.
   - Restricts cancellation strictly to `CONFIRMED` status (cannot cancel once vehicle has entered or if already completed/expired).
   - Sets reservation to `CANCELLED` and releases the spot back to `AVAILABLE`.

6. **`expire_reservations()` -> `INTEGER`**
   - Atomic CTE query: updates all `CONFIRMED` reservations older than 60 minutes to `EXPIRED` and frees their associated spots to `AVAILABLE`.
   - Called periodically on dashboard loads and before reservation queries.

---

### 7.2 Database Triggers

| # | Trigger Name | Target Table | Timing | Description |
|---|---|---|---|---|
| 1 | `trg_reservation_spot_type_check` | `reservations` | BEFORE INSERT | Validates that spot `vehicle_type` matches vehicle `vehicle_type`. |
| 2 | `trg_check_spot_on_reservation` | `reservations` | BEFORE INSERT | Prevents reserving spots in `OCCUPIED` or `MAINTENANCE` status. |
| 3 | `trg_after_reservation_insert` | `reservations` | AFTER INSERT | Automatically sets parking spot status to `RESERVED` upon booking. |
| 4 | `trg_after_session_insert` | `parking_sessions` | AFTER INSERT | Automatically sets parking spot status to `OCCUPIED` upon vehicle entry. |
| 5 | `trg_after_reservation_update` | `reservations` | AFTER UPDATE | Releases spot to `AVAILABLE` when reservation changes to `CANCELLED` or `EXPIRED`. |
| 6 | `trg_after_session_update` | `parking_sessions` | AFTER UPDATE | Releases spot to `AVAILABLE` when session transitions from `ACTIVE` to `COMPLETED`. |
| 7 | `trg_check_active_sessions` | `parking_sessions` | BEFORE INSERT | Belt-and-suspenders guard preventing duplicate active sessions for the same vehicle. |
| 8 | `trg_audit_reservation_changes` | `reservations` | AFTER INSERT/UPDATE | Logs reservation state changes, old/new status, and user ID into `audit_logs`. |
| 9 | `trg_audit_session_changes` | `parking_sessions` | AFTER INSERT/UPDATE | Logs session start, exit, and billed amounts into `audit_logs`. |
| 10 | `trg_audit_payment_insert` | `payments` | AFTER INSERT | Logs payment transactions and reference numbers into `audit_logs`. |
| 11 | `trg_validate_payment_before_insert` | `payments` | BEFORE INSERT | Invariant check: ensures session is `COMPLETED` and payment amount matches session fee. |
| 12 | `trg_audit_spots` | `parking_spots` | AFTER UPDATE | Logs spot status changes into `audit_logs`. |

---

### 7.3 Constraints & Partial Unique Indexes

- **Partial Unique Index 1**: `uix_vehicle_active_reservation`
  ```sql
  CREATE UNIQUE INDEX uix_vehicle_active_reservation 
  ON reservations(vehicle_id) 
  WHERE status IN ('CONFIRMED', 'ACTIVE');
  ```
  *Ensures at the database index level that a vehicle can never have more than one open reservation.*

- **Partial Unique Index 2**: `uix_vehicle_active_session`
  ```sql
  CREATE UNIQUE INDEX uix_vehicle_active_session 
  ON parking_sessions(vehicle_id) 
  WHERE status = 'ACTIVE';
  ```
  *Ensures at the database index level that a vehicle can never be parked in two spots simultaneously.*

- **Foreign Key Cascades**: Zones, spots, and gate terminals cascade deletions from parent facilities. Critical audit and session records protect referential integrity.
- **Check Constraints**: `tariffs.hourly_rate > 0`, `payments.amount >= 0`, `spot_number > 0`.

---

## 8. Web Application Routes

### Public & Authentication Routes (`app/routes/auth.py`)
- `GET  /` -> Redirects to `/customer/dashboard` or `/admin/dashboard` based on role, or `/login`.
- `GET  /login` -> Renders login form with demo credentials hint.
- `POST /login` -> Verifies bcrypt hash, creates session token, sets HTTP-only cookie.
- `GET  /register` -> Renders customer registration form.
- `POST /register` -> Validates input, hashes password, creates customer account.
- `GET  /logout` -> Invalidates session and clears cookie.

### Customer Routes (`app/routes/customer.py`)
- `GET  /customer/dashboard` -> Summary KPI cards, current active booking, recent reservations.
- `GET  /customer/vehicles` -> Lists customer's registered vehicles.
- `POST /customer/vehicles` -> Adds new vehicle (enforces unique license plate).
- `GET  /customer/reserve` -> Booking form with live facility capacity indicators.
- `POST /customer/reserve` -> Calls `create_reservation()` database function.
- `GET  /customer/reservations` -> Complete reservation history with status badges.
- `POST /customer/reservations/{id}/cancel` -> Calls `cancel_reservation()` database function.

### Admin Routes (`app/routes/admin.py`)
- `GET  /admin/dashboard` -> Real-time system stats (spots breakdown, revenue, recent entries).
- `GET  /admin/reservations` -> View all active/confirmed bookings.
- `GET  /admin/entry` -> Vehicle entry gate interface.
- `POST /admin/entry` -> Calls `process_vehicle_entry()` database function.
- `GET  /admin/exit` -> Vehicle checkout & payment gate interface.
- `POST /admin/exit` -> Calls `process_vehicle_exit()` database function.
- `GET  /admin/sessions` -> Dual-tab view of parking sessions and simulated payment receipts.
- `GET  /admin/facilities` -> Facilities and zones summary.
- `GET  /admin/spots` -> Comprehensive spot occupancy grid.
- `GET  /admin/reports/occupancy` -> Visual occupancy progress bars and revenue analytics.

---

## 9. Academic Demonstration Checklist (Viva Ready)

- [x] **No React**: Pure server-side Jinja2 HTML with Bootstrap 5.
- [x] **No Mock Payments**: Realistic simulation with unique reference codes (`PAY-XXXXXXXX`).
- [x] **Zero Business Logic Cheating**: All spot allocation, pricing, locking, status changes, and invariants execute in PL/pgSQL.
- [x] **Concurrency Safety**: `FOR UPDATE SKIP LOCKED` verified.
- [x] **60-Minute Grace Expiration**: Automatic lazy and periodic batch expiration via `expire_reservations()`.
- [x] **Full Audit Trail**: Every insertion and update recorded in `audit_logs` with JSONB payloads.
- [x] **Error Messaging**: PostgreSQL exceptions (`RAISE EXCEPTION`) captured and cleanly rendered in Bootstrap alert banners.
