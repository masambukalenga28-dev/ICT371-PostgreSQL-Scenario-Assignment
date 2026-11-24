-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q07;
SET search_path TO ict371_q07, public;

-- (a) Tables
CREATE TABLE customers(customer_id SERIAL PRIMARY KEY,full_name TEXT NOT NULL);
CREATE TABLE readings(reading_id SERIAL PRIMARY KEY,customer_id INT NOT NULL REFERENCES customers,
 reading_month DATE NOT NULL CHECK(EXTRACT(DAY FROM reading_month)=1),
 previous_reading NUMERIC(14,3) NOT NULL CHECK(previous_reading>=0),current_reading NUMERIC(14,3) NOT NULL CHECK(current_reading>=0),UNIQUE(customer_id,reading_month));
CREATE TABLE bills(bill_id SERIAL PRIMARY KEY,reading_id INT NOT NULL UNIQUE REFERENCES readings,
 charge NUMERIC(16,2) NOT NULL CHECK(charge>=0),amount_paid NUMERIC(16,2) NOT NULL DEFAULT 0 CHECK(amount_paid>=0 AND amount_paid<=charge),due_on DATE NOT NULL);
CREATE TABLE receivable_snapshot(snapshot_date DATE PRIMARY KEY,total_due NUMERIC(20,2) NOT NULL CHECK(total_due>=0));
INSERT INTO customers(full_name) VALUES('Alice Banda'),('Brian Phiri'),('Chanda Zulu');
-- (b) Two-band tariff, rounding once to exactly two decimal places.
CREATE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC LANGUAGE plpgsql SET search_path = ict371_q07, public AS $$
BEGIN
 IF p_units IS NULL OR p_units<0 THEN RAISE EXCEPTION 'Invalid consumption'; END IF;
 RETURN ROUND(LEAST(p_units,10)*5+GREATEST(p_units-10,0)*8,2);
END; $$;
-- (c) Generate one bill per reading.
CREATE PROCEDURE pr_generate_bill(p_reading_id INT,p_due_on DATE) LANGUAGE plpgsql SET search_path = ict371_q07, public AS $$
DECLARE v_units NUMERIC;
BEGIN
 IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date required'; END IF;
 SELECT current_reading-previous_reading INTO v_units FROM readings WHERE reading_id=p_reading_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading'; END IF;
 IF EXISTS(SELECT 1 FROM bills WHERE reading_id=p_reading_id) THEN RAISE EXCEPTION 'Reading already billed'; END IF;
 INSERT INTO bills(reading_id,charge,amount_paid,due_on) VALUES(p_reading_id,fn_water_charge(v_units),0,p_due_on);
END; $$;
-- (d) Trigger protects direct inserts and updates.
CREATE FUNCTION fn_validate_reading() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q07, public AS $$
BEGIN
 IF NEW.current_reading<NEW.previous_reading THEN RAISE EXCEPTION 'Current reading below previous reading'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_validate_reading BEFORE INSERT OR UPDATE ON readings FOR EACH ROW EXECUTE FUNCTION fn_validate_reading();
-- (a) continued: six readings, including 0, 10 and >10 units.
INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading) VALUES
 (1,(date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE,100,100),
 (2,(date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE,50,60),
 (3,(date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE,70,85),
 (1,(date_trunc('month',CURRENT_DATE)-INTERVAL '1 month')::DATE,100,112),
 (2,(date_trunc('month',CURRENT_DATE)-INTERVAL '1 month')::DATE,60,65),
 (3,(date_trunc('month',CURRENT_DATE)-INTERVAL '1 month')::DATE,85,105);
CALL pr_generate_bill(1,CURRENT_DATE-10);
CALL pr_generate_bill(2,CURRENT_DATE-10);
CALL pr_generate_bill(3,CURRENT_DATE-10);
CALL pr_generate_bill(4,CURRENT_DATE+10);
CALL pr_generate_bill(5,CURRENT_DATE+10);
CALL pr_generate_bill(6,CURRENT_DATE+10);
UPDATE bills SET amount_paid=charge WHERE reading_id=2;
UPDATE bills SET amount_paid=30 WHERE reading_id=3;
-- (e) Overdue unpaid bills only.
CREATE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,b.due_on,b.charge-b.amount_paid AS outstanding_amount
FROM bills b JOIN readings r USING(reading_id) JOIN customers c USING(customer_id)
WHERE b.due_on<CURRENT_DATE AND b.amount_paid<b.charge;
SELECT * FROM v_overdue_bills;
-- (f) Partial index narrows the scan to unpaid bills and supports due-date range searches.
CREATE INDEX idx_unpaid_bill_due ON bills(due_on) WHERE amount_paid<charge;
EXPLAIN ANALYZE SELECT * FROM bills WHERE due_on<CURRENT_DATE AND amount_paid<charge;
-- (g) All unpaid balances (including not yet overdue), replaced daily.
CREATE PROCEDURE pr_refresh_receivables() LANGUAGE plpgsql SET search_path = ict371_q07, public AS $$
BEGIN
 INSERT INTO receivable_snapshot(snapshot_date,total_due)
 SELECT CURRENT_DATE,COALESCE(SUM(charge-amount_paid),0) FROM bills WHERE amount_paid<charge
 ON CONFLICT(snapshot_date) DO UPDATE SET total_due=EXCLUDED.total_due;
END; $$;
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
SELECT fn_water_charge(0),fn_water_charge(10),fn_water_charge(15);

DO $$ BEGIN
 IF fn_water_charge(0)<>0 OR fn_water_charge(10)<>50 OR fn_water_charge(15)<>90
 OR (SELECT COUNT(*) FROM bills)<>6 OR (SELECT COUNT(*) FROM v_overdue_bills)<>1
 OR NOT EXISTS(SELECT 1 FROM receivable_snapshot WHERE snapshot_date=CURRENT_DATE AND total_due=281)
 THEN RAISE EXCEPTION 'TEST FAILED: billing'; END IF;
 BEGIN UPDATE readings SET current_reading=previous_reading-1 WHERE reading_id=1; RAISE EXCEPTION 'TEST FAILED: invalid reading accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Current reading below previous reading' THEN RAISE; END IF; END;
 BEGIN CALL pr_generate_bill(1,CURRENT_DATE); RAISE EXCEPTION 'TEST FAILED: duplicate bill';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Reading already billed' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: tariff bands, reading validation, duplicate prevention and snapshot';
END; $$;

COMMIT;

-- (g) Schedule: 30 0 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q07_receivables', '30 0 * * *', $job$CALL ict371_q07.pr_refresh_receivables();$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q07_receivables';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q07_receivables', '30 0 * * *', $command$CALL ict371_q07.pr_refresh_receivables();$command$;
    RAISE NOTICE 'Scheduled ict371_q07_receivables, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
