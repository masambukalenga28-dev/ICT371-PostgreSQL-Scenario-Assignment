-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q03;
SET search_path TO ict371_q03, public;

-- (a) Tables
CREATE TABLE books(book_id SERIAL PRIMARY KEY,title TEXT NOT NULL);
CREATE TABLE loans(
 loan_id SERIAL PRIMARY KEY, book_id INT NOT NULL REFERENCES books, borrower_name TEXT NOT NULL,
 borrowed_on DATE NOT NULL, due_on DATE NOT NULL CHECK(due_on>=borrowed_on),
 returned_on DATE CHECK(returned_on>=borrowed_on), fine_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(fine_amount>=0)
);
CREATE TABLE loan_audit(audit_id SERIAL PRIMARY KEY,loan_id INT NOT NULL REFERENCES loans,
 old_returned_on DATE,new_returned_on DATE,changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE overdue_summary(snapshot_date DATE PRIMARY KEY,overdue_count BIGINT NOT NULL CHECK(overdue_count>=0),total_fine NUMERIC(16,2) NOT NULL CHECK(total_fine>=0));
INSERT INTO books(title) VALUES('Database Systems'),('Computer Networks'),('Software Engineering');
INSERT INTO loans(book_id,borrower_name,borrowed_on,due_on) VALUES
 (1,'Alice',CURRENT_DATE-20,CURRENT_DATE-10),(2,'Brian',CURRENT_DATE-7,CURRENT_DATE+3),
 (3,'Chanda',CURRENT_DATE-15,CURRENT_DATE-5),(1,'David',CURRENT_DATE-8,CURRENT_DATE-2),
 (2,'Esther',CURRENT_DATE-10,CURRENT_DATE),(3,'Grace',CURRENT_DATE-4,CURRENT_DATE+6);
-- (b) Function
CREATE FUNCTION fn_loan_fine(p_loan_id INT,p_as_of DATE) RETURNS NUMERIC LANGUAGE plpgsql SET search_path = ict371_q03, public AS $$
DECLARE v_due DATE; v_return DATE;
BEGIN
 IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date required'; END IF;
 SELECT due_on,returned_on INTO v_due,v_return FROM loans WHERE loan_id=p_loan_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan'; END IF;
 RETURN 2::NUMERIC*GREATEST(0,LEAST(p_as_of,COALESCE(v_return,p_as_of))-v_due);
END; $$;
-- (c) Procedure
CREATE PROCEDURE pr_return_loan(p_loan_id INT,p_returned_on DATE) LANGUAGE plpgsql SET search_path = ict371_q03, public AS $$
DECLARE v_loan loans%ROWTYPE;
BEGIN
 SELECT * INTO v_loan FROM loans WHERE loan_id=p_loan_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan'; END IF;
 IF v_loan.returned_on IS NOT NULL THEN RAISE EXCEPTION 'Loan already returned'; END IF;
 IF p_returned_on IS NULL OR p_returned_on<v_loan.borrowed_on THEN RAISE EXCEPTION 'Invalid return date'; END IF;
 UPDATE loans SET returned_on=p_returned_on,fine_amount=fn_loan_fine(p_loan_id,p_returned_on) WHERE loan_id=p_loan_id;
END; $$;
-- (d) Trigger
CREATE FUNCTION fn_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q03, public AS $$
BEGIN
 INSERT INTO loan_audit(loan_id,old_returned_on,new_returned_on,changed_at)
 VALUES(NEW.loan_id,OLD.returned_on,NEW.returned_on,CURRENT_TIMESTAMP);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_loan_audit AFTER UPDATE ON loans FOR EACH ROW
 WHEN(OLD.returned_on IS DISTINCT FROM NEW.returned_on) EXECUTE FUNCTION fn_loan_audit();
CALL pr_return_loan(3,CURRENT_DATE-2); -- 3 days late, K6
CALL pr_return_loan(4,CURRENT_DATE-2); -- on due date, K0
-- (e) View
CREATE VIEW v_overdue_loans AS
SELECT b.title AS book_title,l.borrower_name,l.due_on,fn_loan_fine(l.loan_id,CURRENT_DATE) AS fine_amount
FROM loans l JOIN books b USING(book_id) WHERE l.returned_on IS NULL AND l.due_on<CURRENT_DATE;
SELECT * FROM v_overdue_loans;
-- (f) Partial index stores only unreturned loans, ordered by book_id.
CREATE INDEX idx_open_loans_book ON loans(book_id) WHERE returned_on IS NULL;
EXPLAIN ANALYZE SELECT * FROM loans WHERE book_id=1 AND returned_on IS NULL;
-- (g) Count overdue, still-unreturned loans as of the snapshot date; exclude not-yet-borrowed loans.
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE) LANGUAGE plpgsql SET search_path = ict371_q03, public AS $$
BEGIN
 IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date required'; END IF;
 INSERT INTO overdue_summary(snapshot_date,overdue_count,total_fine)
 SELECT p_as_of,COUNT(*),COALESCE(SUM(fn_loan_fine(loan_id,p_as_of)),0)
 FROM loans WHERE borrowed_on<=p_as_of AND due_on<p_as_of AND (returned_on IS NULL OR returned_on>p_as_of)
 ON CONFLICT(snapshot_date) DO UPDATE SET overdue_count=EXCLUDED.overdue_count,total_fine=EXCLUDED.total_fine;
END; $$;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;
SELECT * FROM loan_audit;
SELECT fn_loan_fine(3,CURRENT_DATE),fn_loan_fine(4,CURRENT_DATE);

DO $$ BEGIN
 UPDATE loans SET returned_on=returned_on WHERE loan_id=3;
 IF fn_loan_fine(3,CURRENT_DATE)<>6 OR fn_loan_fine(4,CURRENT_DATE)<>0
 OR (SELECT COUNT(*) FROM loan_audit)<>2
 OR NOT EXISTS(SELECT 1 FROM overdue_summary WHERE snapshot_date=CURRENT_DATE AND overdue_count=1 AND total_fine=20)
 THEN RAISE EXCEPTION 'TEST FAILED: library'; END IF;
 BEGIN CALL pr_return_loan(3,CURRENT_DATE); RAISE EXCEPTION 'TEST FAILED: repeated return';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Loan already returned' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: fines, returns, audit and summary';
END; $$;

COMMIT;

-- (g) Schedule: 10 0 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q03_overdue', '10 0 * * *', $job$CALL ict371_q03.pr_refresh_overdue(CURRENT_DATE);$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q03_overdue';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q03_overdue', '10 0 * * *', $command$CALL ict371_q03.pr_refresh_overdue(CURRENT_DATE);$command$;
    RAISE NOTICE 'Scheduled ict371_q03_overdue, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
