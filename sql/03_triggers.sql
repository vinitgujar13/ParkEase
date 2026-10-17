-- =============================================================================
-- FILE: 03_triggers.sql
-- PROJECT: Vehicle Parking Management System
-- DESCRIPTION: All PL/pgSQL trigger functions and trigger definitions.
--
-- Covers:
--   1.  Validate reservation spot/vehicle type match
--   2.  Prevent reservation of OCCUPIED or MAINTENANCE spots
--   3.  Set spot RESERVED after confirmed reservation insert
--   4.  Set spot OCCUPIED after active session insert
--   5.  Release spot AVAILABLE on reservation CANCELLED/EXPIRED
--   6.  Release spot AVAILABLE on session COMPLETED
--   7.  Prevent multiple active sessions for the same vehicle
--   8.  Audit log for reservations (INSERT / UPDATE)
--   9.  Audit log for parking_sessions (INSERT / UPDATE)
--   10. Audit log for payments (INSERT)
--   11. Validate payment against completed session + matching amount
--   12. Audit log for parking_spots status changes
-- =============================================================================

-- ---------------------------------------------------------------------------
-- TRIGGER 1: Validate reservation spot/vehicle type match
-- Ensures the vehicle type recorded on the vehicle matches the vehicle type
-- the target spot was designed for before allowing a reservation to be made.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_validate_reservation_spot_type()
RETURNS TRIGGER AS $$
DECLARE
    v_spot_type    vehicle_type;
    v_vehicle_type vehicle_type;
BEGIN
    SELECT ps.vehicle_type
      INTO v_spot_type
      FROM parking_spots ps
     WHERE ps.id = NEW.spot_id;

    SELECT v.vehicle_type
      INTO v_vehicle_type
      FROM vehicles v
     WHERE v.id = NEW.vehicle_id;

    IF v_spot_type <> v_vehicle_type THEN
        RAISE EXCEPTION
            'Spot vehicle type % does not match vehicle type %',
            v_spot_type, v_vehicle_type;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reservation_spot_type_check
    BEFORE INSERT ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_validate_reservation_spot_type();

-- ---------------------------------------------------------------------------
-- TRIGGER 2: Prevent reservation of OCCUPIED or MAINTENANCE spots
-- Reads the current spot status at reservation time and rejects the row if
-- the spot is not in a bookable state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_spot_availability()
RETURNS TRIGGER AS $$
DECLARE
    v_status spot_status;
BEGIN
    SELECT status
      INTO v_status
      FROM parking_spots
     WHERE id = NEW.spot_id;

    IF v_status IN ('OCCUPIED', 'MAINTENANCE') THEN
        RAISE EXCEPTION
            'Spot is not available for reservation. Current status: %',
            v_status;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_spot_on_reservation
    BEFORE INSERT ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_check_spot_availability();

-- ---------------------------------------------------------------------------
-- TRIGGER 3: After confirmed reservation inserted, set spot RESERVED
-- Transitions the spot to RESERVED so no other reservation or session can
-- claim it while a CONFIRMED reservation is open.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_spot_reserved()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'CONFIRMED' THEN
        UPDATE parking_spots
           SET status = 'RESERVED'
         WHERE id = NEW.spot_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_reservation_insert
    AFTER INSERT ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_set_spot_reserved();

-- ---------------------------------------------------------------------------
-- TRIGGER 4: After active session insert, set spot OCCUPIED
-- Marks the spot OCCUPIED the moment a parking session becomes ACTIVE,
-- preventing any concurrent reservation or session from taking the same spot.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_spot_occupied()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        UPDATE parking_spots
           SET status = 'OCCUPIED'
         WHERE id = NEW.spot_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_session_insert
    AFTER INSERT ON parking_sessions
    FOR EACH ROW EXECUTE FUNCTION trg_set_spot_occupied();

-- ---------------------------------------------------------------------------
-- TRIGGER 5: After reservation CANCELLED or EXPIRED, release spot AVAILABLE
-- Only releases the spot when the previous status was CONFIRMED so that a
-- spot is not incorrectly freed by transitions that never held it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_release_spot_on_reservation_change()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IN ('CANCELLED', 'EXPIRED') AND OLD.status = 'CONFIRMED' THEN
        UPDATE parking_spots
           SET status = 'AVAILABLE'
         WHERE id = NEW.spot_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_reservation_update
    AFTER UPDATE ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_release_spot_on_reservation_change();

-- ---------------------------------------------------------------------------
-- TRIGGER 6: After session COMPLETED, release spot AVAILABLE
-- Frees the spot only when a transition from ACTIVE → COMPLETED occurs,
-- guarding against spurious updates or replays.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_release_spot_on_session_complete()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'COMPLETED' AND OLD.status = 'ACTIVE' THEN
        UPDATE parking_spots
           SET status = 'AVAILABLE'
         WHERE id = NEW.spot_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_session_update
    AFTER UPDATE ON parking_sessions
    FOR EACH ROW EXECUTE FUNCTION trg_release_spot_on_session_complete();

-- ---------------------------------------------------------------------------
-- TRIGGER 7: Prevent multiple active sessions for the same vehicle
-- Acts as an application-level belt-and-suspenders check in addition to any
-- partial unique index defined on parking_sessions(vehicle_id) WHERE status = 'ACTIVE'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_prevent_multiple_active_sessions()
RETURNS TRIGGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
      INTO v_count
      FROM parking_sessions
     WHERE vehicle_id = NEW.vehicle_id
       AND status = 'ACTIVE';

    IF v_count > 0 THEN
        RAISE EXCEPTION 'Vehicle already has an active parking session';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_active_sessions
    BEFORE INSERT ON parking_sessions
    FOR EACH ROW EXECUTE FUNCTION trg_prevent_multiple_active_sessions();

-- ---------------------------------------------------------------------------
-- TRIGGER 8: Audit log for reservations (INSERT / UPDATE)
-- Captures old and new status, user_id, and vehicle_id on every state
-- transition so that a full history of every reservation is preserved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_reservations()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (table_name, operation, record_id, details)
    VALUES (
        'reservations',
        TG_OP,
        COALESCE(NEW.id, OLD.id)::TEXT,
        jsonb_build_object(
            'old_status',  OLD.status,
            'new_status',  NEW.status,
            'user_id',     COALESCE(NEW.user_id,    OLD.user_id),
            'vehicle_id',  COALESCE(NEW.vehicle_id, OLD.vehicle_id)
        )
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_reservation_changes
    AFTER INSERT OR UPDATE ON reservations
    FOR EACH ROW EXECUTE FUNCTION trg_audit_reservations();

-- ---------------------------------------------------------------------------
-- TRIGGER 9: Audit log for parking_sessions (INSERT / UPDATE)
-- Records status transitions, vehicle_id, and the billed amount for every
-- session row that is created or modified.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_sessions()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (table_name, operation, record_id, details)
    VALUES (
        'parking_sessions',
        TG_OP,
        COALESCE(NEW.id, OLD.id)::TEXT,
        jsonb_build_object(
            'old_status', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
            'new_status', NEW.status,
            'vehicle_id', NEW.vehicle_id,
            'amount',     NEW.amount
        )
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_session_changes
    AFTER INSERT OR UPDATE ON parking_sessions
    FOR EACH ROW EXECUTE FUNCTION trg_audit_sessions();

-- ---------------------------------------------------------------------------
-- TRIGGER 10: Audit log for payments (INSERT)
-- Persists key payment metadata — session linkage, amount, status, and the
-- external reference number — at the moment a payment row is created.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_payments()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (table_name, operation, record_id, details)
    VALUES (
        'payments',
        TG_OP,
        NEW.id::TEXT,
        jsonb_build_object(
            'session_id',        NEW.session_id,
            'amount',            NEW.amount,
            'status',            NEW.status,
            'reference_number',  NEW.reference_number
        )
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_payment_insert
    AFTER INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_audit_payments();

-- ---------------------------------------------------------------------------
-- TRIGGER 11: Validate payment before insert
-- Enforces two invariants:
--   (a) The referenced parking session must exist and be in COMPLETED status.
--   (b) The payment amount must exactly match the session's calculated amount.
-- This prevents stray or incorrect payments from being recorded.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_validate_payment()
RETURNS TRIGGER AS $$
DECLARE
    v_session parking_sessions%ROWTYPE;
BEGIN
    SELECT *
      INTO v_session
      FROM parking_sessions
     WHERE id = NEW.session_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Session not found for payment';
    END IF;

    IF v_session.status <> 'COMPLETED' THEN
        RAISE EXCEPTION
            'Payment can only be recorded for completed sessions. Session status: %',
            v_session.status;
    END IF;

    IF v_session.amount IS NULL OR v_session.amount <> NEW.amount THEN
        RAISE EXCEPTION
            'Payment amount % does not match session amount %',
            NEW.amount, v_session.amount;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_payment_before_insert
    BEFORE INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_validate_payment();

-- ---------------------------------------------------------------------------
-- TRIGGER 12: Audit log for parking_spots status changes
-- Fires only when the status column actually changes, avoiding noise from
-- updates to unrelated columns (e.g. last_maintained_at).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_spot_changes()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs (table_name, operation, record_id, details)
        VALUES (
            'parking_spots',
            'UPDATE',
            NEW.id::TEXT,
            jsonb_build_object(
                'old_status',   OLD.status,
                'new_status',   NEW.status,
                'spot_number',  NEW.spot_number
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_spots
    AFTER UPDATE ON parking_spots
    FOR EACH ROW EXECUTE FUNCTION trg_audit_spot_changes();
