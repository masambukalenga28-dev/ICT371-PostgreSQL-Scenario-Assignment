-- ============================================================
-- ICT371 PostgreSQL Scenario 1
-- University Library Book Loans
-- Student Number: 202404703
-- File: scenario_1_202404703.sql
-- ============================================================


-- ============================================================
-- 1. CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

DROP TABLE IF EXISTS book_loans;
DROP TABLE IF EXISTS books;

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(100) NOT NULL,
    available_copies INTEGER NOT NULL CHECK (available_copies >= 0)
);

CREATE TABLE book_loans (
    loan_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    quantity INTEGER NOT NULL,
    loan_status VARCHAR(20) NOT NULL
);


-- Add at least three books
INSERT INTO books (title, available_copies)
VALUES
('Database Systems', 5),
('Computer Networks', 2),
('Software Engineering', 0);


-- Display the books
SELECT * FROM books;


-- ============================================================
-- 2. IF ELSIF ELSE
-- Display whether a book is unavailable, low on copies,
-- or sufficiently stocked.
-- ============================================================

DO $$
DECLARE
    book_record RECORD;
BEGIN
    FOR book_record IN
        SELECT title, available_copies
        FROM books
    LOOP

        IF book_record.available_copies = 0 THEN

            RAISE NOTICE '%: Book is unavailable.',
                book_record.title;

        ELSIF book_record.available_copies <= 2 THEN

            RAISE NOTICE '%: Book has low copies.',
                book_record.title;

        ELSE

            RAISE NOTICE '%: Book is sufficiently stocked.',
                book_record.title;

        END IF;

    END LOOP;
END $$;


-- ============================================================
-- 3. WHILE LOOP AND NUMERIC FOR LOOP
-- ============================================================

-- WHILE loop: display three overdue reminder numbers

DO $$
DECLARE
    reminder_number INTEGER := 1;
BEGIN

    WHILE reminder_number <= 3 LOOP

        RAISE NOTICE 'Overdue Reminder Number: %',
            reminder_number;

        reminder_number := reminder_number + 1;

    END LOOP;

END $$;


-- Numeric FOR loop: display three library shelf numbers

DO $$
BEGIN

    FOR shelf_number IN 1..3 LOOP

        RAISE NOTICE 'Library Shelf Number: %',
            shelf_number;

    END LOOP;

END $$;


-- ============================================================
-- 4. CREATE borrow_book PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE borrow_book(
    p_student_number VARCHAR,
    p_book_id INTEGER,
    p_quantity INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_available_copies INTEGER;
BEGIN

    -- Check whether the requested quantity is valid
    IF p_quantity <= 0 THEN

        RAISE EXCEPTION
            'Invalid quantity. Quantity must be greater than zero.';

    END IF;


    -- Get available copies
    SELECT available_copies
    INTO v_available_copies
    FROM books
    WHERE book_id = p_book_id;


    -- Check whether the book exists
    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Book ID % does not exist.',
            p_book_id;

    END IF;


    -- Check whether enough copies are available
    IF v_available_copies < p_quantity THEN

        RAISE NOTICE
            'Loan rejected. Only % copies are available.',
            v_available_copies;

        RETURN;

    END IF;


    -- Reduce available copies
    UPDATE books
    SET available_copies = available_copies - p_quantity
    WHERE book_id = p_book_id;


    -- Record the loan
    INSERT INTO book_loans
    (
        student_number,
        book_id,
        quantity,
        loan_status
    )
    VALUES
    (
        p_student_number,
        p_book_id,
        p_quantity,
        'Borrowed'
    );


    RAISE NOTICE
        'Loan recorded successfully for student %.',
        p_student_number;

END;
$$;


-- ============================================================
-- 5. CALL borrow_book
-- Two valid loans and one request exceeding available copies
-- ============================================================

-- Valid loan 1
CALL borrow_book('202404703', 1, 2);

-- Valid loan 2
CALL borrow_book('202404704', 2, 1);

-- Invalid loan: requests more copies than available
CALL borrow_book('202404705', 2, 5);


-- Query both tables
SELECT * FROM books;

SELECT * FROM book_loans;


-- ============================================================
-- 6. CREATE return_book PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE return_book(
    p_loan_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_book_id INTEGER;
    v_quantity INTEGER;
    v_status VARCHAR(20);
BEGIN

    -- Find the loan
    SELECT book_id, quantity, loan_status
    INTO v_book_id, v_quantity, v_status
    FROM book_loans
    WHERE loan_id = p_loan_id;


    -- Check whether the loan exists
    IF NOT FOUND THEN

        RAISE NOTICE
            'Loan ID % does not exist.',
            p_loan_id;

        RETURN;

    END IF;


    -- Only restore copies if the loan is still borrowed
    IF v_status = 'Borrowed' THEN

        UPDATE books
        SET available_copies = available_copies + v_quantity
        WHERE book_id = v_book_id;


        UPDATE book_loans
        SET loan_status = 'Returned'
        WHERE loan_id = p_loan_id;


        RAISE NOTICE
            'Loan % returned successfully.',
            p_loan_id;

    ELSE

        RAISE NOTICE
            'Loan % has already been returned. Copies were not restored.',
            p_loan_id;

    END IF;

END;
$$;


-- Return loan 1
CALL return_book(1);

-- Call it a second time for the same loan
CALL return_book(1);


-- Display results
SELECT * FROM books;

SELECT * FROM book_loans;


-- ============================================================
-- 7. EXPLICIT CURSOR
-- Display books with few copies remaining
-- ============================================================

DO $$
DECLARE

    book_cursor CURSOR FOR
        SELECT book_id, title, available_copies
        FROM books
        WHERE available_copies <= 2;

    book_record RECORD;

BEGIN

    OPEN book_cursor;

    LOOP

        FETCH book_cursor INTO book_record;

        EXIT WHEN NOT FOUND;

        RAISE NOTICE
            'Low stock book: ID %, Title: %, Copies remaining: %',
            book_record.book_id,
            book_record.title,
            book_record.available_copies;

    END LOOP;

    CLOSE book_cursor;

END $$;


-- ============================================================
-- 8. TRY TO BORROW ZERO COPIES
-- Handle invalid quantity with an EXCEPTION block
-- ============================================================

DO $$
BEGIN

    BEGIN

        CALL borrow_book('202404706', 1, 0);

    EXCEPTION
        WHEN OTHERS THEN

            RAISE NOTICE
                'Exception handled: %',
                SQLERRM;

    END;

END $$;


-- ============================================================
-- 9. FINAL QUERIES
-- Show final book quantities and loan statuses
-- ============================================================

SELECT
    book_id,
    title,
    available_copies
FROM books
ORDER BY book_id;


SELECT
    loan_id,
    student_number,
    book_id,
    quantity,
    loan_status
FROM book_loans
ORDER BY loan_id;


-- ============================================================
-- END OF SCENARIO 1
-- ============================================================