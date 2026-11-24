-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q08;
SET search_path TO ict371_q08, public;

-- (a) Tables and vehicles
CREATE TABLE vehicles(vehicle_id SERIAL PRIMARY KEY,registration TEXT UNIQUE NOT NULL,
 current_odometer BIGINT NOT NULL CHECK(current_odometer>=0),last_service_odometer BIGINT NOT NULL CHECK(last_service_odometer>=0 AND last_service_odometer<=current_odometer));
CREATE TABLE trips(trip_id SERIAL PRIMARY KEY,vehicle_id INT NOT NULL REFERENCES vehicles,
 trip_on DATE NOT NULL,start_odometer BIGINT NOT NULL CHECK(start_odometer>=0),end_odometer BIGINT NOT NULL CHECK(end_odometer>start_odometer));
CREATE TABLE service_alerts(vehicle_id INT PRIMARY KEY REFERENCES vehicles,km_since_service BIGINT NOT NULL CHECK(km_since_service>=5000),flagged_on DATE NOT NULL);
INSERT INTO vehicles(registration,current_odometer,last_service_odometer) VALUES
 ('ABC 101 ZM',10000,6000),('ABC 102 ZM',20000,19000),('ABC 103 ZM',30000,25000);
-- (b) Function
CREATE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = ict371_q08, public AS $$
DECLARE v_km BIGINT;
BEGIN
 SELECT current_odometer-last_service_odometer INTO v_km FROM vehicles WHERE vehicle_id=p_vehicle_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
 RETURN v_km>=5000;
END; $$;
-- (c) Procedure validates and inserts only; trigger owns the odometer update.
CREATE PROCEDURE pr_record_trip(p_vehicle_id INT,p_trip_on DATE,p_start BIGINT,p_end BIGINT) LANGUAGE plpgsql SET search_path = ict371_q08, public AS $$
BEGIN
 PERFORM 1 FROM vehicles WHERE vehicle_id=p_vehicle_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
 IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL OR p_start<0 OR p_end<=p_start THEN RAISE EXCEPTION 'Invalid trip mileage or date'; END IF;
 INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer) VALUES(p_vehicle_id,p_trip_on,p_start,p_end);
END; $$;
-- (d) Trigger locks vehicle, checks the start and changes odometer exactly once.
CREATE FUNCTION fn_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q08, public AS $$
DECLARE v_current BIGINT;
BEGIN
 SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
 IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL OR NEW.start_odometer<0 OR NEW.end_odometer<=NEW.start_odometer THEN RAISE EXCEPTION 'Invalid trip mileage'; END IF;
 IF NEW.start_odometer<>v_current THEN RAISE EXCEPTION 'Trip start must match current odometer'; END IF;
 UPDATE vehicles SET current_odometer=NEW.end_odometer WHERE vehicle_id=NEW.vehicle_id;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_trip_odometer BEFORE INSERT ON trips FOR EACH ROW EXECUTE FUNCTION fn_trip_odometer();
-- (a) continued: six trips through procedure after trigger installation.
CALL pr_record_trip(1,CURRENT_DATE-2,10000,10600);
CALL pr_record_trip(1,CURRENT_DATE-1,10600,11000);
CALL pr_record_trip(2,CURRENT_DATE-2,20000,20200);
CALL pr_record_trip(2,CURRENT_DATE-1,20200,20500);
CALL pr_record_trip(3,CURRENT_DATE-2,30000,30100);
CALL pr_record_trip(3,CURRENT_DATE-1,30100,30300);
-- (e) View
CREATE VIEW v_service_due AS SELECT registration,current_odometer-last_service_odometer AS km_since_service
FROM vehicles WHERE current_odometer-last_service_odometer>=5000;
SELECT * FROM v_service_due;
-- (f) Equality on vehicle_id followed by trip_on supports vehicle-specific date range queries.
CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id,trip_on);
EXPLAIN ANALYZE SELECT * FROM trips WHERE vehicle_id=1 AND trip_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
-- (g) Synchronize due alerts; remove vehicles no longer due after service.
CREATE PROCEDURE pr_refresh_service_alerts() LANGUAGE plpgsql SET search_path = ict371_q08, public AS $$
BEGIN
 INSERT INTO service_alerts(vehicle_id,km_since_service,flagged_on)
 SELECT vehicle_id,current_odometer-last_service_odometer,CURRENT_DATE FROM vehicles WHERE current_odometer-last_service_odometer>=5000
 ON CONFLICT(vehicle_id) DO UPDATE SET km_since_service=EXCLUDED.km_since_service,flagged_on=EXCLUDED.flagged_on;
 DELETE FROM service_alerts a USING vehicles v WHERE a.vehicle_id=v.vehicle_id AND v.current_odometer-v.last_service_odometer<5000;
END; $$;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;
SELECT * FROM vehicles;
SELECT fn_service_due(1),fn_service_due(2),fn_service_due(3);

DO $$ BEGIN
 IF NOT fn_service_due(1) OR fn_service_due(2) OR NOT fn_service_due(3)
 OR (SELECT COUNT(*) FROM service_alerts)<>2 OR (SELECT current_odometer FROM vehicles WHERE vehicle_id=1)<>11000
 THEN RAISE EXCEPTION 'TEST FAILED: service threshold or odometer'; END IF;
 BEGIN CALL pr_record_trip(1,CURRENT_DATE,10000,12000); RAISE EXCEPTION 'TEST FAILED: wrong start accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Trip start must match current odometer' THEN RAISE; END IF; END;
 -- Temporarily service vehicle 1 to test alert removal; roll back the test changes.
 BEGIN
  UPDATE vehicles SET last_service_odometer=current_odometer WHERE vehicle_id=1;
  CALL pr_refresh_service_alerts();
  IF EXISTS(SELECT 1 FROM service_alerts WHERE vehicle_id=1) THEN RAISE EXCEPTION 'TEST FAILED: stale alert'; END IF;
  RAISE EXCEPTION 'ROLLBACK TEST';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'ROLLBACK TEST' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: mileage, service threshold, alert refresh and removal';
END; $$;

COMMIT;

-- (g) Schedule: 0 6 * * 1. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q08_service', '0 6 * * 1', $job$CALL ict371_q08.pr_refresh_service_alerts();$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q08_service';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q08_service', '0 6 * * 1', $command$CALL ict371_q08.pr_refresh_service_alerts();$command$;
    RAISE NOTICE 'Scheduled ict371_q08_service, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
