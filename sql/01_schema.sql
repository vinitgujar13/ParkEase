-- =============================================================================
-- Vehicle Parking Management System — Database Schema
-- File   : 01_schema.sql
-- Engine : PostgreSQL 14+
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extension
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------------
CREATE TYPE user_role           AS ENUM ('ADMIN', 'CUSTOMER', 'FACILITY_ADMIN');
CREATE TYPE vehicle_type        AS ENUM ('TWO_WHEELER', 'FOUR_WHEELER');
CREATE TYPE spot_status         AS ENUM ('AVAILABLE', 'RESERVED', 'OCCUPIED', 'MAINTENANCE');
CREATE TYPE reservation_status  AS ENUM ('CONFIRMED', 'ACTIVE', 'COMPLETED', 'CANCELLED', 'EXPIRED');
CREATE TYPE session_status      AS ENUM ('ACTIVE', 'COMPLETED');
CREATE TYPE payment_method      AS ENUM ('SIMULATED');
CREATE TYPE payment_status      AS ENUM ('PAID', 'PENDING', 'FAILED');
CREATE TYPE terminal_type       AS ENUM ('ENTRY', 'EXIT');
CREATE TYPE facility_status     AS ENUM ('ACTIVE', 'INACTIVE');

-- ---------------------------------------------------------------------------
-- TABLE 1 — users
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id            UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name          TEXT         NOT NULL,
    email         TEXT         NOT NULL UNIQUE,
    password_hash TEXT         NOT NULL,
    role          user_role    NOT NULL DEFAULT 'CUSTOMER',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- TABLE 2 — parking_facilities
-- ---------------------------------------------------------------------------
CREATE TABLE parking_facilities (
    id         UUID             NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name       TEXT             NOT NULL,
    address    TEXT             NOT NULL,
    city       TEXT             NOT NULL,
    status     facility_status  NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

-- Link users with role FACILITY_ADMIN to a specific parking facility
ALTER TABLE users ADD COLUMN facility_id UUID REFERENCES parking_facilities(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- TABLE 3 — parking_zones
-- ---------------------------------------------------------------------------
CREATE TABLE parking_zones (
    id          UUID  NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    facility_id UUID  NOT NULL REFERENCES parking_facilities(id) ON DELETE CASCADE,
    name        TEXT  NOT NULL,
    UNIQUE (facility_id, name)
);

-- ---------------------------------------------------------------------------
-- TABLE 4 — parking_spots
-- ---------------------------------------------------------------------------
CREATE TABLE parking_spots (
    id           UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    zone_id      UUID         NOT NULL REFERENCES parking_zones(id) ON DELETE CASCADE,
    spot_number  INTEGER      NOT NULL,
    vehicle_type vehicle_type NOT NULL,
    status       spot_status  NOT NULL DEFAULT 'AVAILABLE',
    UNIQUE (zone_id, spot_number)
);

-- ---------------------------------------------------------------------------
-- TABLE 5 — vehicles
-- ---------------------------------------------------------------------------
CREATE TABLE vehicles (
    id            UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id       UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    license_plate TEXT         NOT NULL UNIQUE,
    vehicle_type  vehicle_type NOT NULL,
    model         TEXT         NOT NULL,
    color         TEXT         NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- TABLE 6 — gate_terminals
-- ---------------------------------------------------------------------------
CREATE TABLE gate_terminals (
    id          UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    facility_id UUID          NOT NULL REFERENCES parking_facilities(id) ON DELETE CASCADE,
    name        TEXT          NOT NULL,
    terminal_type terminal_type NOT NULL
);

-- ---------------------------------------------------------------------------
-- TABLE 7 — tariffs
-- ---------------------------------------------------------------------------
CREATE TABLE tariffs (
    id           UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    zone_id      UUID         NOT NULL REFERENCES parking_zones(id) ON DELETE CASCADE,
    vehicle_type vehicle_type NOT NULL,
    hourly_rate  NUMERIC(10,2) NOT NULL CHECK (hourly_rate > 0),
    UNIQUE (zone_id, vehicle_type)
);

-- ---------------------------------------------------------------------------
-- TABLE 8 — reservations
-- ---------------------------------------------------------------------------
CREATE TABLE reservations (
    id         UUID               NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id    UUID               NOT NULL REFERENCES users(id),
    vehicle_id UUID               NOT NULL REFERENCES vehicles(id),
    spot_id    UUID               NOT NULL REFERENCES parking_spots(id),
    start_time TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
    end_time   TIMESTAMPTZ,
    status     reservation_status NOT NULL DEFAULT 'CONFIRMED',
    created_at TIMESTAMPTZ        NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- TABLE 9 — parking_sessions
-- ---------------------------------------------------------------------------
CREATE TABLE parking_sessions (
    id                UUID           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    reservation_id    UUID           REFERENCES reservations(id),
    vehicle_id        UUID           NOT NULL REFERENCES vehicles(id),
    spot_id           UUID           NOT NULL REFERENCES parking_spots(id),
    entry_terminal_id UUID           NOT NULL REFERENCES gate_terminals(id),
    exit_terminal_id  UUID           REFERENCES gate_terminals(id),
    entry_time        TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    exit_time         TIMESTAMPTZ,
    amount            NUMERIC(10,2),
    status            session_status NOT NULL DEFAULT 'ACTIVE'
);

-- ---------------------------------------------------------------------------
-- TABLE 10 — payments
-- ---------------------------------------------------------------------------
CREATE TABLE payments (
    id               UUID           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id       UUID           NOT NULL REFERENCES parking_sessions(id) UNIQUE,
    amount           NUMERIC(10,2)  NOT NULL CHECK (amount >= 0),
    payment_method   payment_method NOT NULL DEFAULT 'SIMULATED',
    status           payment_status NOT NULL DEFAULT 'PAID',
    paid_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    reference_number TEXT           NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------------
-- TABLE 11 — audit_logs
-- ---------------------------------------------------------------------------
CREATE TABLE audit_logs (
    id         BIGSERIAL    PRIMARY KEY,
    table_name TEXT         NOT NULL,
    operation  TEXT         NOT NULL,
    record_id  TEXT,
    details    JSONB,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ===========================================================================
-- INDEXES
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Partial unique indexes
-- ---------------------------------------------------------------------------
-- Prevent a vehicle from holding more than one active/confirmed reservation
CREATE UNIQUE INDEX uix_vehicle_active_reservation
    ON reservations (vehicle_id)
    WHERE status IN ('CONFIRMED', 'ACTIVE');

-- Prevent a vehicle from having more than one active parking session
CREATE UNIQUE INDEX uix_vehicle_active_session
    ON parking_sessions (vehicle_id)
    WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- reservations
-- ---------------------------------------------------------------------------
CREATE INDEX idx_reservations_user_id  ON reservations (user_id);
CREATE INDEX idx_reservations_spot_id  ON reservations (spot_id);
CREATE INDEX idx_reservations_status   ON reservations (status);

-- ---------------------------------------------------------------------------
-- parking_sessions
-- ---------------------------------------------------------------------------
CREATE INDEX idx_parking_sessions_vehicle_id ON parking_sessions (vehicle_id);
CREATE INDEX idx_parking_sessions_status     ON parking_sessions (status);

-- ---------------------------------------------------------------------------
-- vehicles
-- ---------------------------------------------------------------------------
CREATE INDEX idx_vehicles_user_id ON vehicles (user_id);

-- ---------------------------------------------------------------------------
-- parking_spots
-- ---------------------------------------------------------------------------
CREATE INDEX idx_parking_spots_zone_id ON parking_spots (zone_id);
CREATE INDEX idx_parking_spots_status  ON parking_spots (status);

-- ---------------------------------------------------------------------------
-- audit_logs
-- ---------------------------------------------------------------------------
CREATE INDEX idx_audit_logs_table_name ON audit_logs (table_name);
CREATE INDEX idx_audit_logs_record_id  ON audit_logs (record_id);
