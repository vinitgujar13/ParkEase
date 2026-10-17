-- =============================================================================
-- Vehicle Parking Management System
-- File: 02_functions_procedures.sql
-- Description: PL/pgSQL functions for core parking business logic
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- 1. calculate_parking_fee
--    Calculates parking fee for a session based on entry time, zone tariff,
--    and vehicle type. Minimum charge: 1 hour, rounded up to full hours.
-- =============================================================================
CREATE OR REPLACE FUNCTION calculate_parking_fee(
    p_session_id UUID,
    p_exit_at    TIMESTAMPTZ DEFAULT NOW()
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_entry_time   TIMESTAMPTZ;
    v_zone_id      UUID;
    v_vehicle_type vehicle_type;
    v_hourly_rate  NUMERIC(10,2);
    v_duration_h   NUMERIC;
    v_hours        INTEGER;
    v_fee          NUMERIC(10,2);
BEGIN
    -- Fetch session entry time, spot zone, and vehicle type
    SELECT
        ps.entry_time,
        sp.zone_id,
        v.vehicle_type
    INTO
        v_entry_time,
        v_zone_id,
        v_vehicle_type
    FROM parking_sessions ps
    JOIN parking_spots sp ON sp.id = ps.spot_id
    JOIN vehicles v ON v.id = ps.vehicle_id
    WHERE ps.id = p_session_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Session not found: %', p_session_id;
    END IF;

    -- Lookup tariff for zone and vehicle type
    SELECT hourly_rate
    INTO v_hourly_rate
    FROM tariffs
    WHERE zone_id = v_zone_id
      AND vehicle_type = v_vehicle_type;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No tariff found for zone % and vehicle type %',
            v_zone_id, v_vehicle_type;
    END IF;

    -- Calculate hours: minimum 1 hour, ceiling to whole hour
    v_duration_h := EXTRACT(EPOCH FROM (p_exit_at - v_entry_time)) / 3600.0;
    v_hours      := GREATEST(1, CEIL(v_duration_h))::INTEGER;
    v_fee        := (v_hours * v_hourly_rate)::NUMERIC(10,2);

    RETURN v_fee;
END;
$$;


-- =============================================================================
-- 2. create_reservation
--    Customer reserves lowest-numbered compatible available spot.
--    Safe under concurrency with FOR UPDATE SKIP LOCKED.
-- =============================================================================
CREATE OR REPLACE FUNCTION create_reservation(
    p_customer_id UUID,
    p_vehicle_id  UUID,
    p_facility_id UUID,
    p_start_at    TIMESTAMPTZ DEFAULT NOW()
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_vehicle_type     vehicle_type;
    v_spot_id          UUID;
    v_reservation_id   UUID;
    v_active_res_count INTEGER;
    v_active_sess_count INTEGER;
BEGIN
    -- Verify vehicle belongs to this customer
    SELECT vehicle_type
    INTO v_vehicle_type
    FROM vehicles
    WHERE id = p_vehicle_id
      AND user_id = p_customer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not belong to user %',
            p_vehicle_id, p_customer_id;
    END IF;

    -- Business Rule: A customer cannot have more than one active reservation or active parking session
    SELECT COUNT(*)
    INTO v_active_res_count
    FROM reservations
    WHERE user_id = p_customer_id
      AND status IN ('CONFIRMED', 'ACTIVE');

    IF v_active_res_count > 0 THEN
        RAISE EXCEPTION 'Customer already has an active reservation';
    END IF;

    SELECT COUNT(*)
    INTO v_active_sess_count
    FROM parking_sessions ps
    JOIN vehicles v ON v.id = ps.vehicle_id
    WHERE v.user_id = p_customer_id
      AND ps.status = 'ACTIVE';

    IF v_active_sess_count > 0 THEN
        RAISE EXCEPTION 'Customer already has an active parking session';
    END IF;

    -- Business Rule: A vehicle can have only one active reservation or active session
    SELECT COUNT(*)
    INTO v_active_res_count
    FROM reservations
    WHERE vehicle_id = p_vehicle_id
      AND status IN ('CONFIRMED', 'ACTIVE');

    IF v_active_res_count > 0 THEN
        RAISE EXCEPTION 'Vehicle already has an active reservation';
    END IF;

    SELECT COUNT(*)
    INTO v_active_sess_count
    FROM parking_sessions
    WHERE vehicle_id = p_vehicle_id
      AND status = 'ACTIVE';

    IF v_active_sess_count > 0 THEN
        RAISE EXCEPTION 'Vehicle already has an active parking session';
    END IF;

    -- Select and lock the lowest-numbered compatible available spot
    SELECT ps.id
    INTO v_spot_id
    FROM parking_spots ps
    JOIN parking_zones pz ON pz.id = ps.zone_id
    WHERE pz.facility_id  = p_facility_id
      AND ps.vehicle_type = v_vehicle_type
      AND ps.status       = 'AVAILABLE'
    ORDER BY ps.spot_number ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_SPOT_AVAILABLE: No available spot for vehicle type % in facility %',
            v_vehicle_type, p_facility_id;
    END IF;

    -- Insert reservation (trigger will transition spot to RESERVED)
    INSERT INTO reservations (
        id,
        user_id,
        vehicle_id,
        spot_id,
        start_time,
        status,
        created_at
    )
    VALUES (
        gen_random_uuid(),
        p_customer_id,
        p_vehicle_id,
        v_spot_id,
        p_start_at,
        'CONFIRMED',
        NOW()
    )
    RETURNING id INTO v_reservation_id;

    RETURN v_reservation_id;
END;
$$;


-- =============================================================================
-- 3. process_vehicle_entry
--    Validates reservation and plate, rejects expired reservations,
--    creates active session, marks reservation ACTIVE, spot becomes OCCUPIED.
-- =============================================================================
CREATE OR REPLACE FUNCTION process_vehicle_entry(
    p_reservation_id    UUID,
    p_license_plate     TEXT,
    p_entry_terminal_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation       reservations%ROWTYPE;
    v_vehicle_id        UUID;
    v_terminal_type     terminal_type;
    v_terminal_facility UUID;
    v_spot_facility     UUID;
    v_session_id        UUID;
BEGIN
    -- Look up reservation
    SELECT * INTO v_reservation
    FROM reservations
    WHERE id = p_reservation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RESERVATION_NOT_FOUND: Reservation % does not exist',
            p_reservation_id;
    END IF;

    -- Status checks
    IF v_reservation.status = 'ACTIVE' THEN
        RAISE EXCEPTION 'Reservation is already ACTIVE (entry already recorded)';
    ELSIF v_reservation.status = 'COMPLETED' THEN
        RAISE EXCEPTION 'Reservation is already COMPLETED';
    ELSIF v_reservation.status = 'CANCELLED' THEN
        RAISE EXCEPTION 'Reservation has been CANCELLED';
    ELSIF v_reservation.status = 'EXPIRED' THEN
        RAISE EXCEPTION 'RESERVATION_EXPIRED: Reservation has EXPIRED';
    ELSIF v_reservation.status <> 'CONFIRMED' THEN
        RAISE EXCEPTION 'Invalid reservation status: %', v_reservation.status;
    END IF;

    -- Check 60-minute expiration rule
    IF NOW() > v_reservation.start_time + INTERVAL '60 minutes' THEN
        UPDATE reservations SET status = 'EXPIRED' WHERE id = p_reservation_id;
        UPDATE parking_spots SET status = 'AVAILABLE' WHERE id = v_reservation.spot_id;
        RAISE EXCEPTION 'RESERVATION_EXPIRED: Reservation expired 60 minutes after start time';
    END IF;

    -- Match license plate with reservation vehicle
    SELECT id INTO v_vehicle_id
    FROM vehicles
    WHERE id = v_reservation.vehicle_id
      AND UPPER(TRIM(license_plate)) = UPPER(TRIM(p_license_plate));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'License plate % does not match the reserved vehicle',
            p_license_plate;
    END IF;

    -- Validate entry terminal
    SELECT terminal_type, facility_id
    INTO v_terminal_type, v_terminal_facility
    FROM gate_terminals
    WHERE id = p_entry_terminal_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Terminal % not found', p_entry_terminal_id;
    END IF;

    IF v_terminal_type <> 'ENTRY' THEN
        RAISE EXCEPTION 'Terminal % is not an ENTRY terminal (type: %)',
            p_entry_terminal_id, v_terminal_type;
    END IF;

    -- Validate terminal facility matches spot facility
    SELECT pz.facility_id INTO v_spot_facility
    FROM parking_spots ps
    JOIN parking_zones pz ON pz.id = ps.zone_id
    WHERE ps.id = v_reservation.spot_id;

    IF v_terminal_facility <> v_spot_facility THEN
        RAISE EXCEPTION 'Terminal % belongs to a different facility than the reserved spot',
            p_entry_terminal_id;
    END IF;

    -- Insert active parking session (trigger will set spot to OCCUPIED)
    INSERT INTO parking_sessions (
        id,
        reservation_id,
        vehicle_id,
        spot_id,
        entry_terminal_id,
        entry_time,
        status
    )
    VALUES (
        gen_random_uuid(),
        p_reservation_id,
        v_vehicle_id,
        v_reservation.spot_id,
        p_entry_terminal_id,
        NOW(),
        'ACTIVE'
    )
    RETURNING id INTO v_session_id;

    -- Update reservation to ACTIVE
    UPDATE reservations
    SET status = 'ACTIVE'
    WHERE id = p_reservation_id;

    RETURN v_session_id;
END;
$$;


-- =============================================================================
-- 4. process_vehicle_exit
--    Finds active session by plate, validates exit terminal, calculates fee,
--    completes session and reservation, frees spot, inserts SIMULATED PAID payment.
-- =============================================================================
CREATE OR REPLACE FUNCTION process_vehicle_exit(
    p_license_plate    TEXT,
    p_exit_terminal_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_session_id        UUID;
    v_reservation_id    UUID;
    v_spot_id           UUID;
    v_terminal_type     terminal_type;
    v_terminal_facility UUID;
    v_spot_facility     UUID;
    v_fee               NUMERIC(10,2);
    v_payment_id        UUID;
    v_ref_no            TEXT;
BEGIN
    -- Find active session for license plate
    SELECT
        ps.id,
        ps.reservation_id,
        ps.spot_id
    INTO
        v_session_id,
        v_reservation_id,
        v_spot_id
    FROM parking_sessions ps
    JOIN vehicles v ON v.id = ps.vehicle_id
    WHERE UPPER(TRIM(v.license_plate)) = UPPER(TRIM(p_license_plate))
      AND ps.status = 'ACTIVE';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_ACTIVE_SESSION: No active parking session found for plate %',
            p_license_plate;
    END IF;

    -- Validate exit terminal
    SELECT terminal_type, facility_id
    INTO v_terminal_type, v_terminal_facility
    FROM gate_terminals
    WHERE id = p_exit_terminal_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Terminal % not found', p_exit_terminal_id;
    END IF;

    IF v_terminal_type <> 'EXIT' THEN
        RAISE EXCEPTION 'Terminal % is not an EXIT terminal (type: %)',
            p_exit_terminal_id, v_terminal_type;
    END IF;

    -- Check terminal facility matches spot facility
    SELECT pz.facility_id INTO v_spot_facility
    FROM parking_spots ps
    JOIN parking_zones pz ON pz.id = ps.zone_id
    WHERE ps.id = v_spot_id;

    IF v_terminal_facility <> v_spot_facility THEN
        RAISE EXCEPTION 'Exit terminal belongs to a different facility than the parked spot';
    END IF;

    -- Calculate fee
    v_fee := calculate_parking_fee(v_session_id, NOW());

    -- Update session to COMPLETED (trigger sets spot to AVAILABLE)
    UPDATE parking_sessions
    SET exit_terminal_id = p_exit_terminal_id,
        exit_time        = NOW(),
        amount           = v_fee,
        status           = 'COMPLETED'
    WHERE id = v_session_id;

    -- Complete reservation if one exists
    IF v_reservation_id IS NOT NULL THEN
        UPDATE reservations
        SET status   = 'COMPLETED',
            end_time = NOW()
        WHERE id = v_reservation_id;
    END IF;

    -- Ensure spot status is AVAILABLE
    UPDATE parking_spots
    SET status = 'AVAILABLE'
    WHERE id = v_spot_id;

    -- Generate reference number and record simulated PAID payment
    v_ref_no := 'PAY-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT, 1, 8));

    INSERT INTO payments (
        id,
        session_id,
        amount,
        payment_method,
        status,
        paid_at,
        reference_number
    )
    VALUES (
        gen_random_uuid(),
        v_session_id,
        v_fee,
        'SIMULATED',
        'PAID',
        NOW(),
        v_ref_no
    )
    RETURNING id INTO v_payment_id;

    RETURN v_payment_id;
END;
$$;


-- =============================================================================
-- 5. cancel_reservation
--    Validates ownership, cancels CONFIRMED reservation, releases spot.
-- =============================================================================
CREATE OR REPLACE FUNCTION cancel_reservation(
    p_reservation_id UUID,
    p_customer_id    UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_reservation
    FROM reservations
    WHERE id = p_reservation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reservation % not found', p_reservation_id;
    END IF;

    IF v_reservation.user_id <> p_customer_id THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Reservation does not belong to this user';
    END IF;

    IF v_reservation.status <> 'CONFIRMED' THEN
        RAISE EXCEPTION 'Cannot cancel reservation with status: %', v_reservation.status;
    END IF;

    UPDATE reservations
    SET status = 'CANCELLED'
    WHERE id = p_reservation_id;

    UPDATE parking_spots
    SET status = 'AVAILABLE'
    WHERE id = v_reservation.spot_id;

    RETURN TRUE;
END;
$$;


-- =============================================================================
-- 6. expire_reservations
--    Expires CONFIRMED reservations older than 60 minutes and releases spots.
-- =============================================================================
CREATE OR REPLACE FUNCTION expire_reservations()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    WITH expired AS (
        UPDATE reservations
        SET status = 'EXPIRED'
        WHERE status = 'CONFIRMED'
          AND start_time < NOW() - INTERVAL '60 minutes'
        RETURNING spot_id
    ),
    released AS (
        UPDATE parking_spots
        SET status = 'AVAILABLE'
        WHERE id IN (SELECT spot_id FROM expired)
        RETURNING id
    )
    SELECT COUNT(*) INTO v_count FROM expired;

    RETURN v_count;
END;
$$;
