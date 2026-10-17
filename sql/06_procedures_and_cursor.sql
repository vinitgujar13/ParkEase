-- =============================================================================
-- Vehicle Parking Management System
-- File: 06_procedures_and_cursor.sql
-- Description: PostgreSQL Stored Procedures and Explicit Cursor Implementation
-- =============================================================================

-- -----------------------------------------------------------------------------
-- REPORTING TABLE: occupancy_report_logs
-- Stores facility-level occupancy snapshots generated via explicit CURSOR.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS occupancy_report_logs (
    id                   BIGSERIAL PRIMARY KEY,
    facility_id          UUID REFERENCES parking_facilities(id) ON DELETE CASCADE,
    facility_name        TEXT NOT NULL,
    total_spots          INTEGER NOT NULL,
    available_spots      INTEGER NOT NULL,
    reserved_spots       INTEGER NOT NULL,
    occupied_spots       INTEGER NOT NULL,
    maintenance_spots    INTEGER NOT NULL,
    occupancy_percentage NUMERIC(5,2) NOT NULL,
    generated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- PROCEDURE 1: expire_old_reservations_proc
-- Administrative procedure to expire CONFIRMED reservations older than 60 mins.
-- Reuses the existing expire_reservations() function and raises a notice.
-- Callable via: CALL expire_old_reservations_proc();
-- =============================================================================
CREATE OR REPLACE PROCEDURE expire_old_reservations_proc()
LANGUAGE plpgsql
AS $$
DECLARE
    v_expired_count INTEGER;
BEGIN
    SELECT expire_reservations()
    INTO v_expired_count;

    RAISE NOTICE 'Procedure completed: % overdue reservation(s) expired and spots released.', v_expired_count;
END;
$$;


-- =============================================================================
-- PROCEDURE 2: set_spot_maintenance_proc
-- Places an AVAILABLE parking spot into MAINTENANCE mode.
-- Rejects OCCUPIED or RESERVED spots with clear exceptions.
-- Uses row-level locking (SELECT ... FOR UPDATE) and logs to audit_logs.
-- Callable via: CALL set_spot_maintenance_proc('<spot_uuid>', 'Floor crack repair');
-- =============================================================================
CREATE OR REPLACE PROCEDURE set_spot_maintenance_proc(
    p_spot_id UUID,
    p_reason  TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_spot RECORD;
    v_active_res INTEGER;
    v_active_sess INTEGER;
BEGIN
    -- 1. Check if spot exists and lock row
    SELECT id, zone_id, spot_number, status
    INTO v_spot
    FROM parking_spots
    WHERE id = p_spot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Spot with ID % does not exist.', p_spot_id;
    END IF;

    -- 2. Reject if currently RESERVED or OCCUPIED
    IF v_spot.status = 'RESERVED' THEN
        RAISE EXCEPTION 'Cannot mark spot % as MAINTENANCE: spot is currently RESERVED.', v_spot.spot_number;
    ELSIF v_spot.status = 'OCCUPIED' THEN
        RAISE EXCEPTION 'Cannot mark spot % as MAINTENANCE: spot is currently OCCUPIED by a vehicle.', v_spot.spot_number;
    ELSIF v_spot.status = 'MAINTENANCE' THEN
        RAISE NOTICE 'Spot % is already under MAINTENANCE.', v_spot.spot_number;
        RETURN;
    END IF;

    -- 3. Verify no active reservation or active parking session exists
    SELECT COUNT(*) INTO v_active_res
    FROM reservations
    WHERE spot_id = p_spot_id AND status IN ('CONFIRMED', 'ACTIVE');

    IF v_active_res > 0 THEN
        RAISE EXCEPTION 'Cannot mark spot % as MAINTENANCE: active reservation exists.', v_spot.spot_number;
    END IF;

    SELECT COUNT(*) INTO v_active_sess
    FROM parking_sessions
    WHERE spot_id = p_spot_id AND status = 'ACTIVE';

    IF v_active_sess > 0 THEN
        RAISE EXCEPTION 'Cannot mark spot % as MAINTENANCE: active parking session in progress.', v_spot.spot_number;
    END IF;

    -- 4. Transition status to MAINTENANCE
    UPDATE parking_spots
    SET status = 'MAINTENANCE'
    WHERE id = p_spot_id;

    -- 5. Record custom audit log with reason and previous state
    INSERT INTO audit_logs (table_name, operation, record_id, details)
    VALUES (
        'parking_spots',
        'MAINTENANCE',
        p_spot_id::TEXT,
        jsonb_build_object(
            'spot_number', v_spot.spot_number,
            'previous_status', v_spot.status,
            'new_status', 'MAINTENANCE',
            'reason', COALESCE(p_reason, 'Unspecified maintenance')
        )
    );

    RAISE NOTICE 'Spot % (ID: %) successfully placed into MAINTENANCE. Reason: %',
        v_spot.spot_number, p_spot_id, COALESCE(p_reason, 'Unspecified maintenance');
END;
$$;


-- =============================================================================
-- PROCEDURE 3: release_spot_from_maintenance_proc
-- Restores a spot from MAINTENANCE back to AVAILABLE.
-- Rejects if the spot is not currently under MAINTENANCE.
-- Uses row-level locking (FOR UPDATE) and records an audit log.
-- Callable via: CALL release_spot_from_maintenance_proc('<spot_uuid>');
-- =============================================================================
CREATE OR REPLACE PROCEDURE release_spot_from_maintenance_proc(
    p_spot_id UUID
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_spot RECORD;
BEGIN
    -- 1. Check if spot exists and lock row
    SELECT id, spot_number, status
    INTO v_spot
    FROM parking_spots
    WHERE id = p_spot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Spot with ID % does not exist.', p_spot_id;
    END IF;

    -- 2. Reject if spot is not in MAINTENANCE
    IF v_spot.status <> 'MAINTENANCE' THEN
        RAISE EXCEPTION 'Cannot release spot %: current status is %, expected MAINTENANCE.',
            v_spot.spot_number, v_spot.status;
    END IF;

    -- 3. Transition status to AVAILABLE
    UPDATE parking_spots
    SET status = 'AVAILABLE'
    WHERE id = p_spot_id;

    -- 4. Record audit log
    INSERT INTO audit_logs (table_name, operation, record_id, details)
    VALUES (
        'parking_spots',
        'RELEASE_MAINTENANCE',
        p_spot_id::TEXT,
        jsonb_build_object(
            'spot_number', v_spot.spot_number,
            'previous_status', 'MAINTENANCE',
            'new_status', 'AVAILABLE'
        )
    );

    RAISE NOTICE 'Spot % (ID: %) released from MAINTENANCE to AVAILABLE.',
        v_spot.spot_number, p_spot_id;
END;
$$;


-- =============================================================================
-- PROCEDURE 4: generate_occupancy_report_cursor_proc
-- Genuine PostgreSQL explicit CURSOR implementation.
-- Demonstrates:
--   1. DECLARE cursor_name CURSOR FOR SELECT ...
--   2. OPEN cursor_name
--   3. FETCH cursor_name INTO ...
--   4. EXIT WHEN NOT FOUND
--   5. CLOSE cursor_name
--
-- Iterates row-by-row through each active facility, computes spot status totals,
-- calculates occupancy percentage, and writes snapshots to occupancy_report_logs.
-- Callable via: CALL generate_occupancy_report_cursor_proc();
-- =============================================================================
CREATE OR REPLACE PROCEDURE generate_occupancy_report_cursor_proc()
LANGUAGE plpgsql
AS $$
DECLARE
    -- Explicit cursor declaration over active parking facilities
    facility_cursor CURSOR FOR
        SELECT id, name
        FROM parking_facilities
        WHERE status = 'ACTIVE'
        ORDER BY name;

    v_facility_id        UUID;
    v_facility_name      TEXT;
    v_total              INTEGER;
    v_available          INTEGER;
    v_reserved           INTEGER;
    v_occupied           INTEGER;
    v_maintenance        INTEGER;
    v_occupancy_pct      NUMERIC(5,2);
    v_facilities_count   INTEGER := 0;
BEGIN
    -- Clear previous snapshot
    TRUNCATE TABLE occupancy_report_logs;

    -- 1. OPEN CURSOR
    OPEN facility_cursor;

    LOOP
        -- 2. FETCH NEXT ROW
        FETCH facility_cursor INTO v_facility_id, v_facility_name;

        -- 3. EXIT LOOP WHEN CURSOR IS EXHAUSTED
        EXIT WHEN NOT FOUND;

        -- Calculate spot statistics for the current facility
        SELECT
            COUNT(*),
            COUNT(*) FILTER (WHERE ps.status = 'AVAILABLE'),
            COUNT(*) FILTER (WHERE ps.status = 'RESERVED'),
            COUNT(*) FILTER (WHERE ps.status = 'OCCUPIED'),
            COUNT(*) FILTER (WHERE ps.status = 'MAINTENANCE')
        INTO
            v_total,
            v_available,
            v_reserved,
            v_occupied,
            v_maintenance
        FROM parking_zones pz
        JOIN parking_spots ps ON ps.zone_id = pz.id
        WHERE pz.facility_id = v_facility_id;

        -- Calculate occupancy percentage (OCCUPIED + RESERVED) / TOTAL
        IF v_total > 0 THEN
            v_occupancy_pct := ROUND((100.0 * (v_occupied + v_reserved) / v_total)::NUMERIC, 2);
        ELSE
            v_occupancy_pct := 0.00;
        END IF;

        -- Store snapshot row
        INSERT INTO occupancy_report_logs (
            facility_id,
            facility_name,
            total_spots,
            available_spots,
            reserved_spots,
            occupied_spots,
            maintenance_spots,
            occupancy_percentage,
            generated_at
        )
        VALUES (
            v_facility_id,
            v_facility_name,
            COALESCE(v_total, 0),
            COALESCE(v_available, 0),
            COALESCE(v_reserved, 0),
            COALESCE(v_occupied, 0),
            COALESCE(v_maintenance, 0),
            v_occupancy_pct,
            NOW()
        );

        v_facilities_count := v_facilities_count + 1;
    END LOOP;

    -- 4. CLOSE CURSOR
    CLOSE facility_cursor;

    RAISE NOTICE 'Cursor iteration complete: % facilities processed into occupancy_report_logs.', v_facilities_count;
END;
$$;


-- =============================================================================
-- PROCEDURE 5: refresh_parking_statistics_proc
-- Master administrative procedure that cascades cursor reporting and reservation cleanup.
-- Callable via: CALL refresh_parking_statistics_proc();
-- =============================================================================
CREATE OR REPLACE PROCEDURE refresh_parking_statistics_proc()
LANGUAGE plpgsql
AS $$
BEGIN
    CALL generate_occupancy_report_cursor_proc();
    CALL expire_old_reservations_proc();
    RAISE NOTICE 'System refresh complete: Occupancy snapshot updated and reservations cleaned.';
END;
$$;
