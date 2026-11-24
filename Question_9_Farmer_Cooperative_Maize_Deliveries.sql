-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q09;
SET search_path TO ict371_q09, public;

-- (a) Tables and farmers
CREATE TABLE farmers(farmer_id SERIAL PRIMARY KEY,farmer_number TEXT UNIQUE NOT NULL,full_name TEXT NOT NULL);
CREATE TABLE deliveries(delivery_id SERIAL PRIMARY KEY,farmer_id INT NOT NULL REFERENCES farmers,
 grade TEXT NOT NULL CHECK(grade IN('A','B','C')),weight_kg NUMERIC(12,3) NOT NULL CHECK(weight_kg>0),
 unit_rate NUMERIC(10,2) NOT NULL CHECK(unit_rate>0),total_value NUMERIC(16,2) NOT NULL CHECK(total_value>=0),
 delivered_on DATE NOT NULL,is_paid BOOLEAN NOT NULL DEFAULT FALSE);
CREATE TABLE daily_purchases(purchase_date DATE PRIMARY KEY,total_weight NUMERIC(18,3) NOT NULL CHECK(total_weight>=0),
 total_value NUMERIC(20,2) NOT NULL CHECK(total_value>=0));
INSERT INTO farmers(farmer_number,full_name) VALUES('F001','Alice Banda'),('F002','Brian Phiri'),('F003','Chanda Zulu');
-- (b) Grade tariff
CREATE FUNCTION fn_maize_rate(p_grade TEXT) RETURNS NUMERIC LANGUAGE plpgsql SET search_path = ict371_q09, public AS $$
BEGIN
 CASE p_grade WHEN 'A' THEN RETURN 5.00; WHEN 'B' THEN RETURN 4.00; WHEN 'C' THEN RETURN 3.00;
 ELSE RAISE EXCEPTION 'Unsupported grade'; END CASE;
END; $$;
-- (c) Procedure lets the trigger fill price and value.
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INT,p_grade TEXT,p_weight NUMERIC,p_date DATE) LANGUAGE plpgsql SET search_path = ict371_q09, public AS $$
BEGIN
 PERFORM 1 FROM farmers WHERE farmer_id=p_farmer_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer'; END IF;
 IF p_weight IS NULL OR p_weight<=0 OR ROUND(p_weight,3)<=0 OR p_date IS NULL THEN RAISE EXCEPTION 'Invalid delivery weight or date'; END IF;
 PERFORM fn_maize_rate(p_grade);
 INSERT INTO deliveries(farmer_id,grade,weight_kg,delivered_on,is_paid) VALUES(p_farmer_id,p_grade,p_weight,p_date,FALSE);
END; $$;
-- (d) Enforce consistent pricing for every insert/update, including direct SQL.
CREATE FUNCTION fn_price_delivery() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q09, public AS $$
BEGIN
 IF NEW.weight_kg IS NULL OR NEW.weight_kg<=0 THEN RAISE EXCEPTION 'Delivery weight must be positive'; END IF;
 NEW.unit_rate:=fn_maize_rate(NEW.grade);
 NEW.total_value:=ROUND(NEW.weight_kg*NEW.unit_rate,2);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_price_delivery BEFORE INSERT OR UPDATE ON deliveries FOR EACH ROW EXECUTE FUNCTION fn_price_delivery();
-- (a) continued: six deliveries and both payment states, loaded after trigger.
CALL pr_receive_delivery(1,'A',100,CURRENT_DATE-1);
CALL pr_receive_delivery(1,'B',50,CURRENT_DATE-1);
CALL pr_receive_delivery(2,'C',80,CURRENT_DATE-1);
CALL pr_receive_delivery(2,'A',20,CURRENT_DATE-1);
CALL pr_receive_delivery(3,'B',60,CURRENT_DATE-1);
INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on,is_paid) VALUES(3,'C',40,999,999,CURRENT_DATE-1,TRUE);
UPDATE deliveries SET is_paid=TRUE WHERE farmer_id=3;
-- (e) Include farmers with no unpaid deliveries.
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,f.full_name,COALESCE(SUM(d.total_value),0) AS amount_due
FROM farmers f LEFT JOIN deliveries d ON f.farmer_id=d.farmer_id AND NOT d.is_paid
GROUP BY f.farmer_id,f.farmer_number,f.full_name;
SELECT * FROM v_farmer_amount_due;
-- (f) Composite farmer/date index serves equality followed by date-range filtering.
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id,delivered_on);
EXPLAIN ANALYZE SELECT * FROM deliveries WHERE farmer_id=1 AND delivered_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
-- (g) Replace daily totals across paid and unpaid purchases.
CREATE PROCEDURE pr_refresh_purchases(p_day DATE) LANGUAGE plpgsql SET search_path = ict371_q09, public AS $$
BEGIN
 IF p_day IS NULL THEN RAISE EXCEPTION 'Date required'; END IF;
 INSERT INTO daily_purchases(purchase_date,total_weight,total_value)
 SELECT p_day,COALESCE(SUM(weight_kg),0),COALESCE(SUM(total_value),0) FROM deliveries WHERE delivered_on=p_day
 ON CONFLICT(purchase_date) DO UPDATE SET total_weight=EXCLUDED.total_weight,total_value=EXCLUDED.total_value;
END; $$;
CALL pr_refresh_purchases(CURRENT_DATE-1);
CALL pr_refresh_purchases(CURRENT_DATE-1);
SELECT * FROM daily_purchases;
SELECT * FROM deliveries;
SELECT fn_maize_rate('A'),fn_maize_rate('B'),fn_maize_rate('C');

DO $$ BEGIN
 IF (SELECT COUNT(*) FROM deliveries)<>6 OR NOT EXISTS(SELECT 1 FROM deliveries WHERE delivery_id=6 AND unit_rate=3 AND total_value=120)
 OR NOT EXISTS(SELECT 1 FROM v_farmer_amount_due WHERE farmer_number='F003' AND amount_due=0)
 OR NOT EXISTS(SELECT 1 FROM daily_purchases WHERE purchase_date=CURRENT_DATE-1 AND total_weight=350 AND total_value=1400)
 THEN RAISE EXCEPTION 'TEST FAILED: maize pricing or totals'; END IF;
 BEGIN UPDATE deliveries SET weight_kg=0 WHERE delivery_id=1; RAISE EXCEPTION 'TEST FAILED: zero weight accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Delivery weight must be positive' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: grade pricing, direct SQL pricing, unpaid balances and daily totals';
END; $$;

COMMIT;

-- (g) Schedule: 30 1 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q09_purchases', '30 1 * * *', $job$CALL ict371_q09.pr_refresh_purchases(CURRENT_DATE - 1);$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q09_purchases';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q09_purchases', '30 1 * * *', $command$CALL ict371_q09.pr_refresh_purchases(CURRENT_DATE - 1);$command$;
    RAISE NOTICE 'Scheduled ict371_q09_purchases, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
