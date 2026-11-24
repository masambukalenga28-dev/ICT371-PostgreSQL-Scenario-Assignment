-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q04;
SET search_path TO ict371_q04, public;

-- (a) Tables
CREATE TABLE patients(patient_id SERIAL PRIMARY KEY,full_name TEXT NOT NULL);
CREATE TABLE doctors(doctor_id SERIAL PRIMARY KEY,full_name TEXT NOT NULL);
CREATE TABLE appointments(
 appointment_id SERIAL PRIMARY KEY,patient_id INT NOT NULL REFERENCES patients,doctor_id INT NOT NULL REFERENCES doctors,
 appointment_day DATE NOT NULL,slot_time TIME NOT NULL CHECK(slot_time IN(TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00')),
 status TEXT NOT NULL CHECK(status IN('BOOKED','ATTENDED','CANCELLED'))
);
-- Additional unique partial index guarantees no clashes even with concurrent inserts.
CREATE UNIQUE INDEX uq_doctor_slot_live ON appointments(doctor_id,appointment_day,slot_time) WHERE status<>'CANCELLED';
CREATE TABLE clinic_summary(summary_date DATE PRIMARY KEY,booked_count BIGINT NOT NULL CHECK(booked_count>=0),
 attended_count BIGINT NOT NULL CHECK(attended_count>=0),cancelled_count BIGINT NOT NULL CHECK(cancelled_count>=0));
INSERT INTO patients(full_name) VALUES('Alice Banda'),('Brian Phiri'),('Chanda Zulu');
INSERT INTO doctors(full_name) VALUES('Dr Mwansa'),('Dr Tembo'),('Dr Sakala');
-- (b) Function
CREATE FUNCTION fn_daily_load(p_doctor_id INT,p_day DATE) RETURNS BIGINT LANGUAGE plpgsql SET search_path = ict371_q04, public AS $$
BEGIN
 IF p_day IS NULL THEN RAISE EXCEPTION 'Date required'; END IF;
 PERFORM 1 FROM doctors WHERE doctor_id=p_doctor_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor'; END IF;
 RETURN (SELECT COUNT(*) FROM appointments WHERE doctor_id=p_doctor_id AND appointment_day=p_day AND status<>'CANCELLED');
END; $$;
-- (c) Procedure
CREATE PROCEDURE pr_book_appointment(p_patient_id INT,p_doctor_id INT,p_day DATE,p_slot TIME) LANGUAGE plpgsql SET search_path = ict371_q04, public AS $$
BEGIN
 PERFORM 1 FROM patients WHERE patient_id=p_patient_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient'; END IF;
 PERFORM 1 FROM doctors WHERE doctor_id=p_doctor_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor'; END IF;
 IF p_day IS NULL OR p_day<CURRENT_DATE OR p_slot IS NULL OR p_slot NOT IN(TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00') THEN
  RAISE EXCEPTION 'Invalid appointment date or slot'; END IF;
 INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status) VALUES(p_patient_id,p_doctor_id,p_day,p_slot,'BOOKED');
END; $$;
-- (d) Trigger: exclude the row itself on UPDATE.
CREATE FUNCTION fn_prevent_clash() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q04, public AS $$
DECLARE v_exclude INT;
BEGIN
 IF TG_OP='UPDATE' THEN v_exclude:=OLD.appointment_id; END IF;
 IF NEW.status<>'CANCELLED' AND EXISTS(
 SELECT 1 FROM appointments a WHERE a.doctor_id=NEW.doctor_id AND a.appointment_day=NEW.appointment_day
 AND a.slot_time=NEW.slot_time AND a.status<>'CANCELLED' AND (v_exclude IS NULL OR a.appointment_id<>v_exclude))
 THEN RAISE EXCEPTION 'Doctor slot already occupied'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_prevent_clash BEFORE INSERT OR UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_prevent_clash();
-- (a) continued: six appointments, including reuse of a cancelled slot.
INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status) VALUES
 (1,1,CURRENT_DATE-1,'09:00','ATTENDED'),(2,1,CURRENT_DATE-1,'10:00','CANCELLED'),
 (3,1,CURRENT_DATE-1,'10:00','BOOKED');
CALL pr_book_appointment(1,1,CURRENT_DATE,TIME '09:00');
CALL pr_book_appointment(2,1,CURRENT_DATE,TIME '10:00');
CALL pr_book_appointment(3,2,CURRENT_DATE,TIME '09:00');
-- (e) View
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,d.full_name AS doctor_name,a.slot_time
FROM appointments a JOIN patients p USING(patient_id) JOIN doctors d USING(doctor_id)
WHERE a.appointment_day=CURRENT_DATE AND a.status='BOOKED';
SELECT * FROM v_today_appointments;
-- (f) Non-unique date/doctor index supports daily schedules, including cancelled appointments.
CREATE INDEX idx_appointment_day_doctor ON appointments(appointment_day,doctor_id);
EXPLAIN ANALYZE SELECT * FROM appointments WHERE appointment_day=CURRENT_DATE AND doctor_id=1;
-- (g) Refresh summary
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE) LANGUAGE plpgsql SET search_path = ict371_q04, public AS $$
BEGIN
 IF p_day IS NULL THEN RAISE EXCEPTION 'Date required'; END IF;
 INSERT INTO clinic_summary(summary_date,booked_count,attended_count,cancelled_count)
 SELECT p_day,COUNT(*) FILTER(WHERE status='BOOKED'),COUNT(*) FILTER(WHERE status='ATTENDED'),COUNT(*) FILTER(WHERE status='CANCELLED')
 FROM appointments WHERE appointment_day=p_day
 ON CONFLICT(summary_date) DO UPDATE SET booked_count=EXCLUDED.booked_count,attended_count=EXCLUDED.attended_count,cancelled_count=EXCLUDED.cancelled_count;
END; $$;
CALL pr_refresh_clinic_summary(CURRENT_DATE-1);
CALL pr_refresh_clinic_summary(CURRENT_DATE-1);
SELECT * FROM clinic_summary;
SELECT fn_daily_load(1,CURRENT_DATE),fn_daily_load(3,CURRENT_DATE);

DO $$ BEGIN
 UPDATE appointments SET status=status WHERE appointment_id=4;
 IF fn_daily_load(1,CURRENT_DATE)<>2 OR fn_daily_load(3,CURRENT_DATE)<>0
 OR (SELECT COUNT(*) FROM v_today_appointments)<>3
 OR NOT EXISTS(SELECT 1 FROM clinic_summary WHERE summary_date=CURRENT_DATE-1 AND booked_count=1 AND attended_count=1 AND cancelled_count=1)
 THEN RAISE EXCEPTION 'TEST FAILED: clinic'; END IF;
 BEGIN CALL pr_book_appointment(3,1,CURRENT_DATE,TIME '09:00'); RAISE EXCEPTION 'TEST FAILED: clash accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Doctor slot already occupied' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: load, clash, view and summary';
END; $$;

COMMIT;

-- (g) Schedule: 0 1 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q04_clinic', '0 1 * * *', $job$CALL ict371_q04.pr_refresh_clinic_summary(CURRENT_DATE - 1);$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q04_clinic';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q04_clinic', '0 1 * * *', $command$CALL ict371_q04.pr_refresh_clinic_summary(CURRENT_DATE - 1);$command$;
    RAISE NOTICE 'Scheduled ict371_q04_clinic, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
