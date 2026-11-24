-- ICT371 Advanced Database | Question 2: University Fee Payments
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q02;
SET search_path TO ict371_q02, public;

-- (a) Tables and seed data
CREATE TABLE students (
 student_id SERIAL PRIMARY KEY, student_number VARCHAR(30) UNIQUE NOT NULL,
 full_name TEXT NOT NULL, fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
 payment_id SERIAL PRIMARY KEY, student_id INT NOT NULL REFERENCES students,
 amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), paid_on DATE NOT NULL
);
CREATE TABLE payment_audit (
 audit_id SERIAL PRIMARY KEY, payment_id INT NOT NULL REFERENCES payments,
 student_id INT NOT NULL REFERENCES students, amount NUMERIC(12,2) NOT NULL,
 logged_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE daily_collections (
 collection_date DATE PRIMARY KEY, payment_count BIGINT NOT NULL CHECK (payment_count >= 0),
 total_amount NUMERIC(16,2) NOT NULL CHECK (total_amount >= 0)
);
INSERT INTO students(student_number,full_name,fee_due) VALUES
 ('S001','Alice Banda',3000),('S002','Brian Phiri',2000),('S003','Chanda Zulu',4500);
-- (b) Function
CREATE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = ict371_q02, public AS $$
DECLARE v_due NUMERIC; v_paid NUMERIC;
BEGIN
 SELECT fee_due INTO v_due FROM students WHERE student_id=p_student_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student'; END IF;
 SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE student_id=p_student_id;
 RETURN v_due-v_paid;
END; $$;
-- (c) Procedure: lock student to serialize payments made through this procedure.
CREATE PROCEDURE pr_receive_payment(p_student_id INT,p_amount NUMERIC,p_paid_on DATE)
LANGUAGE plpgsql SET search_path = ict371_q02, public AS $$
BEGIN
 IF p_amount IS NULL OR p_amount<=0 OR p_amount<>ROUND(p_amount,2) OR p_paid_on IS NULL THEN
   RAISE EXCEPTION 'Invalid payment amount or date';
 END IF;
 PERFORM 1 FROM students WHERE student_id=p_student_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student'; END IF;
 IF p_amount>fn_fee_balance(p_student_id) THEN RAISE EXCEPTION 'Payment exceeds balance'; END IF;
 INSERT INTO payments(student_id,amount,paid_on) VALUES(p_student_id,p_amount,p_paid_on);
END; $$;
-- (d) AFTER INSERT audit trigger
CREATE FUNCTION fn_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q02, public AS $$
BEGIN
 INSERT INTO payment_audit(payment_id,student_id,amount,logged_at)
 VALUES(NEW.payment_id,NEW.student_id,NEW.amount,CURRENT_TIMESTAMP);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_payment_audit AFTER INSERT ON payments FOR EACH ROW EXECUTE FUNCTION fn_payment_audit();
-- (a) continued: six payments; student 3 has no payments; student 2 is settled.
CALL pr_receive_payment(1,500,CURRENT_DATE-1);
CALL pr_receive_payment(1,700,CURRENT_DATE-1);
CALL pr_receive_payment(1,300,CURRENT_DATE-1);
CALL pr_receive_payment(2,500,CURRENT_DATE-1);
CALL pr_receive_payment(2,500,CURRENT_DATE-1);
CALL pr_receive_payment(2,1000,CURRENT_DATE-1);
-- (e) View
CREATE VIEW v_fee_balances AS
SELECT s.student_number,s.full_name,s.fee_due-COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM students s LEFT JOIN payments p ON p.student_id=s.student_id
GROUP BY s.student_id,s.student_number,s.full_name,s.fee_due
HAVING s.fee_due-COALESCE(SUM(p.amount),0)>0;
SELECT * FROM v_fee_balances;
-- (f) Equality on student_id first, then date range; supports targeted payment history.
CREATE INDEX idx_payments_student_date ON payments(student_id,paid_on);
EXPLAIN ANALYZE SELECT * FROM payments WHERE student_id=1 AND paid_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
-- (g) Replace daily totals, including days with no payments.
CREATE PROCEDURE pr_refresh_collections(p_day DATE) LANGUAGE plpgsql SET search_path = ict371_q02, public AS $$
BEGIN
 IF p_day IS NULL THEN RAISE EXCEPTION 'Date required'; END IF;
 INSERT INTO daily_collections(collection_date,payment_count,total_amount)
 SELECT p_day,COUNT(*),COALESCE(SUM(amount),0) FROM payments WHERE paid_on=p_day
 ON CONFLICT(collection_date) DO UPDATE SET payment_count=EXCLUDED.payment_count,total_amount=EXCLUDED.total_amount;
END; $$;
CALL pr_refresh_collections(CURRENT_DATE-1);
CALL pr_refresh_collections(CURRENT_DATE-1);
SELECT * FROM daily_collections;
SELECT * FROM payment_audit;
SELECT fn_fee_balance(1),fn_fee_balance(2),fn_fee_balance(3);

DO $$ BEGIN
 IF fn_fee_balance(1)<>1500 OR fn_fee_balance(2)<>0 OR fn_fee_balance(3)<>4500
 OR (SELECT COUNT(*) FROM payment_audit)<>6 OR (SELECT COUNT(*) FROM v_fee_balances)<>2
 OR NOT EXISTS(SELECT 1 FROM daily_collections WHERE collection_date=CURRENT_DATE-1 AND payment_count=6 AND total_amount=3500)
 THEN RAISE EXCEPTION 'TEST FAILED: payments'; END IF;
 BEGIN CALL pr_receive_payment(1,2000,CURRENT_DATE); RAISE EXCEPTION 'TEST FAILED: overpayment accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Payment exceeds balance' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: balances, audit, overpayment and summary';
END; $$;

COMMIT;

-- (g) Schedule: 0 1 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q02_collections', '0 1 * * *', $job$CALL ict371_q02.pr_refresh_collections(CURRENT_DATE - 1);$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q02_collections';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q02_collections', '0 1 * * *', $command$CALL ict371_q02.pr_refresh_collections(CURRENT_DATE - 1);$command$;
    RAISE NOTICE 'Scheduled ict371_q02_collections, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
