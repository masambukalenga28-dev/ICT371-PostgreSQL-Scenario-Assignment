-- ============================================================
-- ICT371 PostgreSQL Scenario 2
-- Computer Laboratory Reservations
-- Student Number: 202404703
-- File: scenario_2_202404703.sql
-- ============================================================


-- ============================================================
-- 1. CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

DROP TABLE IF EXISTS reservations;
DROP TABLE IF EXISTS lab_sessions;

CREATE TABLE lab_sessions (
    session_id SERIAL PRIMARY KEY,
    session_name VARCHAR(100) NOT NULL,
    available_workstations INTEGER NOT NULL
        CHECK (available_workstations >= 0)
);

CREATE TABLE reservations (
    reservation_id SERIAL PRIMARY KEY,
    lecturer VARCHAR(100) NOT NULL,
    session_id INTEGER NOT NULL REFERENCES lab_sessions(session_id),
    workstations INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL
);


-- Add at least three sessions
INSERT INTO lab_sessions
(session_name, available_workstations)
VALUES
('Database Practical', 20),
('Programming Practical', 5),
('Networking Practical', 0);


-- Display sessions
SELECT * FROM lab_sessions;


-- ============================================================
-- 2. IF ELSIF ELSE
-- ============================================================

DO $$
DECLARE
    session_record RECORD;
BEGIN

    FOR session_record IN
        SELECT session_name, available_workstations
        FROM lab_sessions
    LOOP

        IF session_record.available_workstations = 0 THEN

            RAISE NOTICE '%: Session is full.',
                session_record.session_name;

        ELSIF session_record.available_workstations <= 5 THEN

            RAISE NOTICE '%: Session is nearly full.',
                session_record.session_name;

        ELSE

            RAISE NOTICE '%: Session has enough workstations.',
                session_record.session_name;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 3. WHILE LOOP AND NUMERIC FOR LOOP
-- ============================================================

DO $$
DECLARE
    reminder_number INTEGER := 1;
BEGIN

    WHILE reminder_number <= 3 LOOP

        RAISE NOTICE 'Session Preparation Reminder: %',
            reminder_number;

        reminder_number := reminder_number + 1;

    END LOOP;

END $$;


DO $$
BEGIN

    FOR workstation_check IN 1..3 LOOP

        RAISE NOTICE 'Workstation Check Number: %',
            workstation_check;

    END LOOP;

END $$;


-- ============================================================
-- 4. CREATE reserve_workstations PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE reserve_workstations(
    p_lecturer VARCHAR,
    p_session_id INTEGER,
    p_workstations INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INTEGER;
BEGIN

    IF p_workstations <= 0 THEN

        RAISE EXCEPTION
            'Invalid quantity. Workstations must be greater than zero.';

    END IF;


    SELECT available_workstations
    INTO v_available
    FROM lab_sessions
    WHERE session_id = p_session_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Session ID % does not exist.',
            p_session_id;

    END IF;


    IF v_available < p_workstations THEN

        RAISE NOTICE
            'Reservation rejected. Only % workstations are available.',
            v_available;

        RETURN;

    END IF;


    UPDATE lab_sessions
    SET available_workstations =
        available_workstations - p_workstations
    WHERE session_id = p_session_id;


    INSERT INTO reservations
    (
        lecturer,
        session_id,
        workstations,
        status
    )
    VALUES
    (
        p_lecturer,
        p_session_id,
        p_workstations,
        'Reserved'
    );


    RAISE NOTICE
        'Reservation recorded successfully for lecturer %.',
        p_lecturer;

END;
$$;


-- ============================================================
-- 5. TWO VALID RESERVATIONS + ONE EXCEEDING CAPACITY
-- ============================================================

CALL reserve_workstations(
    'Dr. Banda',
    1,
    5
);

CALL reserve_workstations(
    'Dr. Phiri',
    2,
    3
);

CALL reserve_workstations(
    'Dr. Mwansa',
    2,
    10
);


-- Display both tables
SELECT * FROM lab_sessions;

SELECT * FROM reservations;


-- ============================================================
-- 6. CREATE cancel_reservation PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE cancel_reservation(
    p_reservation_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_session_id INTEGER;
    v_workstations INTEGER;
    v_status VARCHAR(20);
BEGIN

    SELECT session_id, workstations, status
    INTO v_session_id, v_workstations, v_status
    FROM reservations
    WHERE reservation_id = p_reservation_id;


    IF NOT FOUND THEN

        RAISE NOTICE
            'Reservation ID % does not exist.',
            p_reservation_id;

        RETURN;

    END IF;


    IF v_status = 'Reserved' THEN

        UPDATE lab_sessions
        SET available_workstations =
            available_workstations + v_workstations
        WHERE session_id = v_session_id;


        UPDATE reservations
        SET status = 'Cancelled'
        WHERE reservation_id = p_reservation_id;


        RAISE NOTICE
            'Reservation % cancelled successfully.',
            p_reservation_id;

    ELSE

        RAISE NOTICE
            'Reservation % has already been cancelled. Workstations were not released again.',
            p_reservation_id;

    END IF;

END;
$$;


-- Cancel reservation 1
CALL cancel_reservation(1);

-- Cancel the same reservation again
CALL cancel_reservation(1);


-- Display results
SELECT * FROM lab_sessions;

SELECT * FROM reservations;


-- ============================================================
-- 7. EXPLICIT CURSOR
-- Display sessions with few workstations remaining
-- ============================================================

DO $$
DECLARE

    session_cursor CURSOR FOR
        SELECT session_id,
               session_name,
               available_workstations
        FROM lab_sessions
        WHERE available_workstations <= 5;

    session_record RECORD;

BEGIN

    OPEN session_cursor;

    LOOP

        FETCH session_cursor INTO session_record;

        EXIT WHEN NOT FOUND;

        RAISE NOTICE
            'Low availability: ID %, Session: %, Workstations remaining: %',
            session_record.session_id,
            session_record.session_name,
            session_record.available_workstations;

    END LOOP;

    CLOSE session_cursor;

END $$;


-- ============================================================
-- 8. REQUEST ZERO WORKSTATIONS
-- Handle invalid quantity using EXCEPTION
-- ============================================================

DO $$
BEGIN

    BEGIN

        CALL reserve_workstations(
            'Dr. Tembo',
            1,
            0
        );

    EXCEPTION
        WHEN OTHERS THEN

            RAISE NOTICE
                'Exception handled: %',
                SQLERRM;

    END;

END $$;


-- ============================================================
-- 9. FINAL QUERIES
-- ============================================================

SELECT
    session_id,
    session_name,
    available_workstations
FROM lab_sessions
ORDER BY session_id;


SELECT
    reservation_id,
    lecturer,
    session_id,
    workstations,
    status
FROM reservations
ORDER BY reservation_id;


-- ============================================================
-- END OF SCENARIO 2
-- ============================================================