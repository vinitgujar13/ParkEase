-- =============================================================================
-- FILE: 04_seed.sql
-- PROJECT: Vehicle Parking Management System
-- DESCRIPTION: Seed / demo data for development and testing.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
-- 1. USERS
-- ===========================================================================

-- Admin user (Admin@123)
INSERT INTO users (id, name, email, password_hash, role)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'Admin User',
    'admin@parking.local',
    crypt('Admin@123', gen_salt('bf')),
    'ADMIN'
);

-- Primary customer (Customer@123)
INSERT INTO users (id, name, email, password_hash, role)
VALUES (
    '00000000-0000-0000-0000-000000000002',
    'John Customer',
    'customer@parking.local',
    crypt('Customer@123', gen_salt('bf')),
    'CUSTOMER'
);

-- Demo customer (Customer@123, owns seed vehicles)
INSERT INTO users (id, name, email, password_hash, role)
VALUES (
    '00000000-0000-0000-0000-000000000003',
    'Demo User',
    'demo@parking.local',
    crypt('Customer@123', gen_salt('bf')),
    'CUSTOMER'
);

-- ===========================================================================
-- 2. PARKING FACILITIES
-- ===========================================================================

-- Facility 1 – Central Park Parking
INSERT INTO parking_facilities (id, name, address, city, status)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'Central Park Parking',
    '123 MG Road, Bangalore',
    'Bangalore',
    'ACTIVE'
);

-- Facility 2 – Tech Hub Parking
INSERT INTO parking_facilities (id, name, address, city, status)
VALUES (
    'a0000000-0000-0000-0000-000000000002',
    'Tech Hub Parking',
    '456 Electronic City, Bangalore',
    'Bangalore',
    'ACTIVE'
);

-- Facility Owner / Facility Admin for Central Park Parking (Owner@123)
INSERT INTO users (id, name, email, password_hash, role, facility_id)
VALUES (
    'f0000000-0000-0000-0000-000000000001',
    'Central Park Owner',
    'owner1@parking.com',
    crypt('Owner@123', gen_salt('bf')),
    'FACILITY_ADMIN',
    'a0000000-0000-0000-0000-000000000001'
) ON CONFLICT (email) DO NOTHING;

-- ===========================================================================
-- 3. PARKING ZONES (2 per facility)
-- ===========================================================================

-- Facility 1 → Zone A
INSERT INTO parking_zones (id, facility_id, name)
VALUES (
    'b0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Zone A (Ground Floor)'
);

-- Facility 1 → Zone B
INSERT INTO parking_zones (id, facility_id, name)
VALUES (
    'b0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Zone B (First Floor)'
);

-- Facility 2 → Zone C
INSERT INTO parking_zones (id, facility_id, name)
VALUES (
    'b0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000002',
    'Zone C (Level 1)'
);

-- Facility 2 → Zone D
INSERT INTO parking_zones (id, facility_id, name)
VALUES (
    'b0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000002',
    'Zone D (Level 2)'
);

-- ===========================================================================
-- 4. PARKING SPOTS
-- ===========================================================================

-- Zone A: spots 1-3 TWO_WHEELER, spots 4-5 FOUR_WHEELER
INSERT INTO parking_spots (id, zone_id, spot_number, vehicle_type, status)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 1, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 2, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 3, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 4, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 5, 'FOUR_WHEELER', 'AVAILABLE');

-- Zone B: spots 1-3 FOUR_WHEELER, spots 4-5 TWO_WHEELER
INSERT INTO parking_spots (id, zone_id, spot_number, vehicle_type, status)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 1, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 2, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 3, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 4, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 5, 'TWO_WHEELER',  'AVAILABLE');

-- Zone C: spots 1-4 TWO_WHEELER, spots 5-6 FOUR_WHEELER
INSERT INTO parking_spots (id, zone_id, spot_number, vehicle_type, status)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 1, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 2, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 3, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 4, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 5, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 6, 'FOUR_WHEELER', 'AVAILABLE');

-- Zone D: spots 1-4 FOUR_WHEELER, spots 5-6 TWO_WHEELER
INSERT INTO parking_spots (id, zone_id, spot_number, vehicle_type, status)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 1, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 2, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 3, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 4, 'FOUR_WHEELER', 'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 5, 'TWO_WHEELER',  'AVAILABLE'),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 6, 'TWO_WHEELER',  'AVAILABLE');

-- ===========================================================================
-- 5. GATE TERMINALS
-- ===========================================================================

-- Facility 1 Terminals
INSERT INTO gate_terminals (id, facility_id, name, terminal_type)
VALUES (
    'c0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Central Park - Entry Gate A',
    'ENTRY'
);

INSERT INTO gate_terminals (id, facility_id, name, terminal_type)
VALUES (
    'c0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Central Park - Exit Gate A',
    'EXIT'
);

-- Facility 2 Terminals
INSERT INTO gate_terminals (id, facility_id, name, terminal_type)
VALUES (
    'c0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000002',
    'Tech Hub - Entry Gate B',
    'ENTRY'
);

INSERT INTO gate_terminals (id, facility_id, name, terminal_type)
VALUES (
    'c0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000002',
    'Tech Hub - Exit Gate B',
    'EXIT'
);

-- ===========================================================================
-- 6. TARIFFS (hourly_rate)
-- ===========================================================================

-- Zone A Tariffs
INSERT INTO tariffs (id, zone_id, vehicle_type, hourly_rate)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 'TWO_WHEELER',  20.00),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 'FOUR_WHEELER', 40.00);

-- Zone B Tariffs
INSERT INTO tariffs (id, zone_id, vehicle_type, hourly_rate)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 'TWO_WHEELER',  25.00),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 'FOUR_WHEELER', 50.00);

-- Zone C Tariffs
INSERT INTO tariffs (id, zone_id, vehicle_type, hourly_rate)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 'TWO_WHEELER',  15.00),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000003', 'FOUR_WHEELER', 35.00);

-- Zone D Tariffs
INSERT INTO tariffs (id, zone_id, vehicle_type, hourly_rate)
VALUES
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 'TWO_WHEELER',  20.00),
    (gen_random_uuid(), 'b0000000-0000-0000-0000-000000000004', 'FOUR_WHEELER', 45.00);

-- ===========================================================================
-- 7. DEMO CUSTOMER VEHICLES
-- ===========================================================================

INSERT INTO vehicles (id, user_id, license_plate, vehicle_type, model, color)
VALUES
    (
        'd0000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000003',
        'KA01AB1234',
        'TWO_WHEELER',
        'Honda Activa',
        'Red'
    ),
    (
        'd0000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000003',
        'KA02CD5678',
        'FOUR_WHEELER',
        'Maruti Swift',
        'White'
    );

COMMIT;
