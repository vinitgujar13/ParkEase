-- ============================================================
-- DEMO QUERIES - Vehicle Parking Management System
-- File: 05_demo_queries.sql
-- Run these in psql or pgAdmin to verify the system
-- ============================================================

-- 1. View all users
SELECT id, name, email, role, created_at FROM users ORDER BY role, name;

-- 2. View all facilities with zone and spot counts
SELECT 
    pf.name AS facility,
    pf.city,
    COUNT(DISTINCT pz.id) AS zones,
    COUNT(ps.id) AS total_spots,
    SUM(CASE WHEN ps.status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available,
    SUM(CASE WHEN ps.status = 'RESERVED'  THEN 1 ELSE 0 END) AS reserved,
    SUM(CASE WHEN ps.status = 'OCCUPIED'  THEN 1 ELSE 0 END) AS occupied
FROM parking_facilities pf
JOIN parking_zones pz ON pz.facility_id = pf.id
JOIN parking_spots ps ON ps.zone_id = pz.id
GROUP BY pf.id, pf.name, pf.city
ORDER BY pf.name;

-- 3. Test create_reservation for demo user's TWO_WHEELER at Central Park Parking
-- SELECT create_reservation(
--     '00000000-0000-0000-0000-000000000003',  -- user_id: demo customer
--     'd0000000-0000-0000-0000-000000000001',  -- vehicle_id: Honda Activa (TWO_WHEELER)
--     'a0000000-0000-0000-0000-000000000001',  -- facility_id: Central Park Parking
--     NOW()
-- ) AS new_reservation_id;

-- 4. View current reservations
SELECT 
    r.id,
    u.name AS customer,
    v.license_plate,
    v.vehicle_type,
    pf.name AS facility,
    pz.name AS zone,
    ps.spot_number,
    r.status,
    r.start_time,
    r.created_at
FROM reservations r
JOIN users u ON u.id = r.user_id
JOIN vehicles v ON v.id = r.vehicle_id
JOIN parking_spots ps ON ps.id = r.spot_id
JOIN parking_zones pz ON pz.id = ps.zone_id
JOIN parking_facilities pf ON pf.id = pz.facility_id
ORDER BY r.created_at DESC;

-- 5. View spot statuses
SELECT 
    pf.name AS facility,
    pz.name AS zone,
    ps.spot_number,
    ps.vehicle_type,
    ps.status
FROM parking_spots ps
JOIN parking_zones pz ON pz.id = ps.zone_id
JOIN parking_facilities pf ON pf.id = pz.facility_id
ORDER BY pf.name, pz.name, ps.spot_number;

-- 6. Test process_vehicle_entry (replace with actual UUID from step 3)
-- SELECT process_vehicle_entry(
--     '<reservation_id_from_step_3>',
--     'KA01AB1234',
--     'c0000000-0000-0000-0000-000000000001'  -- Central Park - Entry Gate A
-- ) AS session_id;

-- 7. Test process_vehicle_exit
-- SELECT process_vehicle_exit(
--     'KA01AB1234',
--     'c0000000-0000-0000-0000-000000000002'  -- Central Park - Exit Gate A
-- ) AS payment_id;

-- 8. View sessions
SELECT 
    ps.id AS session_id,
    v.license_plate,
    v.vehicle_type,
    gt_entry.name AS entry_terminal,
    gt_exit.name AS exit_terminal,
    ps.entry_time,
    ps.exit_time,
    ps.amount,
    ps.status
FROM parking_sessions ps
JOIN vehicles v ON v.id = ps.vehicle_id
JOIN gate_terminals gt_entry ON gt_entry.id = ps.entry_terminal_id
LEFT JOIN gate_terminals gt_exit ON gt_exit.id = ps.exit_terminal_id
ORDER BY ps.entry_time DESC;

-- 9. View payments
SELECT 
    p.id AS payment_id,
    v.license_plate,
    p.amount,
    p.payment_method,
    p.status,
    p.reference_number,
    p.paid_at
FROM payments p
JOIN parking_sessions ps ON ps.id = p.session_id
JOIN vehicles v ON v.id = ps.vehicle_id
ORDER BY p.paid_at DESC;

-- 10. View audit logs
SELECT table_name, operation, record_id, details, created_at
FROM audit_logs
ORDER BY created_at DESC
LIMIT 20;

-- 11. Test expire_reservations
SELECT expire_reservations() AS expired_count;

-- 12. Occupancy report by facility and vehicle type
SELECT 
    pf.name AS facility,
    ps.vehicle_type,
    COUNT(*) AS total_spots,
    SUM(CASE WHEN ps.status = 'OCCUPIED' THEN 1 ELSE 0 END) AS occupied,
    SUM(CASE WHEN ps.status = 'RESERVED' THEN 1 ELSE 0 END) AS reserved,
    SUM(CASE WHEN ps.status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available,
    ROUND(100.0 * SUM(CASE WHEN ps.status IN ('OCCUPIED','RESERVED') THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS occupancy_pct
FROM parking_spots ps
JOIN parking_zones pz ON pz.id = ps.zone_id
JOIN parking_facilities pf ON pf.id = pz.facility_id
GROUP BY pf.id, pf.name, ps.vehicle_type
ORDER BY pf.name, ps.vehicle_type;

-- 13. Revenue report
SELECT 
    pf.name AS facility,
    COALESCE(SUM(p.amount), 0) AS total_revenue,
    COUNT(p.id) AS total_transactions
FROM payments p
JOIN parking_sessions ps ON ps.id = p.session_id
JOIN parking_spots sp ON sp.id = ps.spot_id
JOIN parking_zones pz ON pz.id = sp.zone_id
JOIN parking_facilities pf ON pf.id = pz.facility_id
GROUP BY pf.id, pf.name;

-- 14. Test cancel_reservation (replace with actual UUID)
-- SELECT cancel_reservation('<reservation_id>', '00000000-0000-0000-0000-000000000003');
