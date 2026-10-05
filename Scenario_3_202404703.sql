-- ============================================================
-- ICT371 PostgreSQL Scenario 3
-- Student Hostel Room Allocation
-- Student Number: 202404703
-- File: scenario_3_202404703.sql
-- ============================================================


-- ============================================================
-- 1. CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS hostel_rooms;


CREATE TABLE hostel_rooms (
    room_id SERIAL PRIMARY KEY,
    room_name VARCHAR(50) NOT NULL,
    available_bed_spaces INTEGER NOT NULL
        CHECK (available_bed_spaces >= 0)
);


CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL,
    room_id INTEGER NOT NULL REFERENCES hostel_rooms(room_id),
    status VARCHAR(20) NOT NULL
);


-- Add at least three rooms
INSERT INTO hostel_rooms
(room_name, available_bed_spaces)
VALUES
('Room A', 4),
('Room B', 1),
('Room C', 0);


-- Display rooms
SELECT * FROM hostel_rooms;


-- ============================================================
-- 2. IF ELSIF ELSE
-- Report room availability
-- ============================================================

DO $$
DECLARE
    room_record RECORD;
BEGIN

    FOR room_record IN
        SELECT room_name, available_bed_spaces
        FROM hostel_rooms
    LOOP

        IF room_record.available_bed_spaces = 0 THEN

            RAISE NOTICE
                '%: Room is full.',
                room_record.room_name;

        ELSIF room_record.available_bed_spaces = 1 THEN

            RAISE NOTICE
                '%: Room has one space left.',
                room_record.room_name;

        ELSE

            RAISE NOTICE
                '%: Room has several spaces.',
                room_record.room_name;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 3. WHILE LOOP AND NUMERIC FOR LOOP
-- ============================================================

DO $$
DECLARE
    inspection_day INTEGER := 1;
BEGIN

    WHILE inspection_day <= 3 LOOP

        RAISE NOTICE
            'Hostel Inspection Day: %',
            inspection_day;

        inspection_day := inspection_day + 1;

    END LOOP;

END $$;


DO $$
BEGIN

    FOR room_check IN 1..3 LOOP

        RAISE NOTICE
            'Room Check Number: %',
            room_check;

    END LOOP;

END $$;


-- ============================================================
-- 4. CREATE allocate_room PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE allocate_room(
    p_student_number VARCHAR,
    p_room_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_available_spaces INTEGER;
BEGIN

    -- Check for blank student number
    IF p_student_number IS NULL
       OR TRIM(p_student_number) = '' THEN

        RAISE EXCEPTION
            'Invalid student number. Student number cannot be blank.';

    END IF;


    -- Get available spaces
    SELECT available_bed_spaces
    INTO v_available_spaces
    FROM hostel_rooms
    WHERE room_id = p_room_id;


    -- Check whether room exists
    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Room ID % does not exist.',
            p_room_id;

    END IF;


    -- Check whether space is available
    IF v_available_spaces <= 0 THEN

        RAISE NOTICE
            'Allocation rejected. Room % is full.',
            p_room_id;

        RETURN;

    END IF;


    -- Reduce available spaces
    UPDATE hostel_rooms
    SET available_bed_spaces =
        available_bed_spaces - 1
    WHERE room_id = p_room_id;


    -- Record allocation
    INSERT INTO allocations
    (
        student_number,
        room_id,
        status
    )
    VALUES
    (
        p_student_number,
        p_room_id,
        'Allocated'
    );


    RAISE NOTICE
        'Student % successfully allocated to room %.',
        p_student_number,
        p_room_id;

END;
$$;


-- ============================================================
-- 5. TWO VALID ALLOCATIONS + ONE FULL ROOM
-- ============================================================

CALL allocate_room(
    '202404703',
    1
);


CALL allocate_room(
    '202404704',
    2
);


-- Room 3 is full
CALL allocate_room(
    '202404705',
    3
);


-- Display both tables
SELECT * FROM hostel_rooms;

SELECT * FROM allocations;


-- ============================================================
-- 6. CREATE check_out PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE check_out(
    p_allocation_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_room_id INTEGER;
    v_status VARCHAR(20);
BEGIN

    -- Find allocation
    SELECT room_id, status
    INTO v_room_id, v_status
    FROM allocations
    WHERE allocation_id = p_allocation_id;


    -- Check whether allocation exists
    IF NOT FOUND THEN

        RAISE NOTICE
            'Allocation ID % does not exist.',
            p_allocation_id;

        RETURN;

    END IF;


    -- Only release space if allocation is still active
    IF v_status = 'Allocated' THEN

        UPDATE hostel_rooms
        SET available_bed_spaces =
            available_bed_spaces + 1
        WHERE room_id = v_room_id;


        UPDATE allocations
        SET status = 'Checked Out'
        WHERE allocation_id = p_allocation_id;


        RAISE NOTICE
            'Allocation % checked out successfully.',
            p_allocation_id;

    ELSE

        RAISE NOTICE
            'Allocation % has already been checked out. Bed space was not released again.',
            p_allocation_id;

    END IF;

END;
$$;


-- Check out allocation 1
CALL check_out(1);


-- Call it a second time for the same allocation
CALL check_out(1);


-- Display results
SELECT * FROM hostel_rooms;

SELECT * FROM allocations;


-- ============================================================
-- 7. EXPLICIT CURSOR
-- Display full or nearly full rooms
-- ============================================================

DO $$
DECLARE

    room_cursor CURSOR FOR
        SELECT room_id,
               room_name,
               available_bed_spaces
        FROM hostel_rooms
        WHERE available_bed_spaces <= 1;

    room_record RECORD;

BEGIN

    OPEN room_cursor;

    LOOP

        FETCH room_cursor INTO room_record;

        EXIT WHEN NOT FOUND;

        RAISE NOTICE
            'Full/nearly full room: ID %, Room: %, Spaces remaining: %',
            room_record.room_id,
            room_record.room_name,
            room_record.available_bed_spaces;

    END LOOP;

    CLOSE room_cursor;

END $$;


-- ============================================================
-- 8. BLANK STUDENT NUMBER
-- Handle invalid input with EXCEPTION
-- ============================================================

DO $$
BEGIN

    BEGIN

        CALL allocate_room(
            '',
            1
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
    room_id,
    room_name,
    available_bed_spaces
FROM hostel_rooms
ORDER BY room_id;


SELECT
    allocation_id,
    student_number,
    room_id,
    status
FROM allocations
ORDER BY allocation_id;


-- ============================================================
-- END OF SCENARIO 3
-- ============================================================