-- ============================================================
-- ICT371 PostgreSQL Scenario 6
-- University Event Seat Booking
-- Student Number: 202404703
-- File: scenario_6_202404703.sql
-- ============================================================


-- ============================================================
-- 1. CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS events;


CREATE TABLE events (
    event_id SERIAL PRIMARY KEY,
    event_name VARCHAR(100) NOT NULL,
    available_seats INTEGER NOT NULL
        CHECK (available_seats >= 0)
);


CREATE TABLE bookings (
    booking_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL,
    event_id INTEGER NOT NULL REFERENCES events(event_id),
    number_of_seats INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL
);


-- Add at least three events
INSERT INTO events
(event_name, available_seats)
VALUES
('ICT Conference', 20),
('Sports Gala', 5),
('Career Fair', 0);


-- Display events
SELECT * FROM events;


-- ============================================================
-- 2. IF ELSIF ELSE
-- Report event seat availability
-- ============================================================

DO $$
DECLARE
    event_record RECORD;
BEGIN

    FOR event_record IN
        SELECT event_name, available_seats
        FROM events
    LOOP

        IF event_record.available_seats = 0 THEN

            RAISE NOTICE
                '%: Event is full.',
                event_record.event_name;

        ELSIF event_record.available_seats <= 5 THEN

            RAISE NOTICE
                '%: Event is nearly full.',
                event_record.event_name;

        ELSE

            RAISE NOTICE
                '%: Event has plenty of seats.',
                event_record.event_name;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 3. WHILE LOOP AND NUMERIC FOR LOOP
-- ============================================================

DO $$
DECLARE
    reminder_day INTEGER := 1;
BEGIN

    WHILE reminder_day <= 3 LOOP

        RAISE NOTICE
            'Booking Reminder Day: %',
            reminder_day;

        reminder_day := reminder_day + 1;

    END LOOP;

END $$;


DO $$
BEGIN

    FOR entrance_check IN 1..3 LOOP

        RAISE NOTICE
            'Entrance Check Number: %',
            entrance_check;

    END LOOP;

END $$;


-- ============================================================
-- 4. CREATE book_seats PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE book_seats(
    p_student_number VARCHAR,
    p_event_id INTEGER,
    p_number_of_seats INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_available_seats INTEGER;
BEGIN

    -- Check that requested seats are valid
    IF p_number_of_seats <= 0 THEN

        RAISE EXCEPTION
            'Invalid quantity. Number of seats must be greater than zero.';

    END IF;


    -- Get available seats
    SELECT available_seats
    INTO v_available_seats
    FROM events
    WHERE event_id = p_event_id;


    -- Check whether event exists
    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Event ID % does not exist.',
            p_event_id;

    END IF;


    -- Check whether enough seats are available
    IF v_available_seats < p_number_of_seats THEN

        RAISE NOTICE
            'Booking rejected. Only % seats are available.',
            v_available_seats;

        RETURN;

    END IF;


    -- Reduce available seats
    UPDATE events
    SET available_seats =
        available_seats - p_number_of_seats
    WHERE event_id = p_event_id;


    -- Record booking
    INSERT INTO bookings
    (
        student_number,
        event_id,
        number_of_seats,
        status
    )
    VALUES
    (
        p_student_number,
        p_event_id,
        p_number_of_seats,
        'Booked'
    );


    RAISE NOTICE
        'Booking recorded successfully for student %.',
        p_student_number;

END;
$$;


-- ============================================================
-- 5. TWO VALID BOOKINGS + ONE EXCEEDING AVAILABLE SEATS
-- ============================================================

CALL book_seats(
    '202404703',
    1,
    4
);


CALL book_seats(
    '202404704',
    2,
    2
);


-- Only 3 seats remain in Event 2
CALL book_seats(
    '202404705',
    2,
    5
);


-- Display both tables
SELECT * FROM events;

SELECT * FROM bookings;


-- ============================================================
-- 6. CREATE cancel_booking PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE cancel_booking(
    p_booking_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_id INTEGER;
    v_number_of_seats INTEGER;
    v_status VARCHAR(20);
BEGIN

    -- Find booking
    SELECT event_id,
           number_of_seats,
           status
    INTO v_event_id,
         v_number_of_seats,
         v_status
    FROM bookings
    WHERE booking_id = p_booking_id;


    -- Check whether booking exists
    IF NOT FOUND THEN

        RAISE NOTICE
            'Booking ID % does not exist.',
            p_booking_id;

        RETURN;

    END IF;


    -- Only release seats if booking is still active
    IF v_status = 'Booked' THEN

        UPDATE events
        SET available_seats =
            available_seats + v_number_of_seats
        WHERE event_id = v_event_id;


        UPDATE bookings
        SET status = 'Cancelled'
        WHERE booking_id = p_booking_id;


        RAISE NOTICE
            'Booking % cancelled successfully.',
            p_booking_id;

    ELSE

        RAISE NOTICE
            'Booking % has already been cancelled. Seats were not released again.',
            p_booking_id;

    END IF;

END;
$$;


-- Cancel booking 1
CALL cancel_booking(1);


-- Cancel the same booking again
CALL cancel_booking(1);


-- Display results
SELECT * FROM events;

SELECT * FROM bookings;


-- ============================================================
-- 7. EXPLICIT CURSOR
-- Display full or nearly full events
-- ============================================================

DO $$
DECLARE

    event_cursor CURSOR FOR
        SELECT event_id,
               event_name,
               available_seats
        FROM events
        WHERE available_seats <= 5;

    event_record RECORD;

BEGIN

    OPEN event_cursor;

    LOOP

        FETCH event_cursor INTO event_record;

        EXIT WHEN NOT FOUND;

        RAISE NOTICE
            'Full/nearly full event: ID %, Event: %, Seats remaining: %',
            event_record.event_id,
            event_record.event_name,
            event_record.available_seats;

    END LOOP;

    CLOSE event_cursor;

END $$;


-- ============================================================
-- 8. TRY TO BOOK ZERO SEATS
-- Handle invalid quantity with EXCEPTION
-- ============================================================

DO $$
BEGIN

    BEGIN

        CALL book_seats(
            '202404706',
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
    event_id,
    event_name,
    available_seats
FROM events
ORDER BY event_id;


SELECT
    booking_id,
    student_number,
    event_id,
    number_of_seats,
    status
FROM bookings
ORDER BY booking_id;


-- ============================================================
-- END OF SCENARIO 6
-- ============================================================