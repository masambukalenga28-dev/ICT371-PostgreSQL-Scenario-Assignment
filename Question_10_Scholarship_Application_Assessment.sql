-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q10;
SET search_path TO ict371_q10, public;

-- (a) Tables and seed data: six PENDING applications across three students.
CREATE TABLE students(student_id SERIAL PRIMARY KEY,student_number TEXT UNIQUE NOT NULL,full_name TEXT NOT NULL);
CREATE TABLE applications(application_id SERIAL PRIMARY KEY,student_id INT NOT NULL REFERENCES students,
 age_at_application INT NOT NULL CHECK(age_at_application>0),monthly_income NUMERIC(12,2) NOT NULL CHECK(monthly_income>=0),
 average_mark NUMERIC(5,2) NOT NULL CHECK(average_mark BETWEEN 0 AND 100),submitted_on DATE NOT NULL,
 status TEXT NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','APPROVED','REJECTED')));
CREATE TABLE decision_audit(audit_id SERIAL PRIMARY KEY,application_id INT NOT NULL REFERENCES applications,
 old_status TEXT NOT NULL,new_status TEXT NOT NULL,changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);
INSERT INTO students(student_number,full_name) VALUES('S001','Alice Banda'),('S002','Brian Phiri'),('S003','Chanda Zulu');
INSERT INTO applications(student_id,age_at_application,monthly_income,average_mark,submitted_on,status) VALUES
 (1,18,3000,70,CURRENT_DATE-1,'PENDING'),(2,25,2000,90,CURRENT_DATE-1,'PENDING'),
 (3,17,1000,80,CURRENT_DATE-1,'PENDING'),(1,26,1000,80,CURRENT_DATE-1,'PENDING'),
 (2,21,3000.01,75,CURRENT_DATE-1,'PENDING'),(3,21,1000,69.99,CURRENT_DATE-1,'PENDING');
SELECT * FROM applications;
-- (b) Eligibility function: boundaries inclusive.
CREATE FUNCTION fn_scholarship_eligible(p_age INT,p_income NUMERIC,p_mark NUMERIC) RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = ict371_q10, public AS $$
BEGIN
 IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL OR p_age<=0 OR p_income<0 OR p_mark<0 OR p_mark>100
 THEN RAISE EXCEPTION 'Invalid eligibility inputs'; END IF;
 RETURN p_age BETWEEN 18 AND 25 AND p_income<=3000 AND p_mark>=70;
END; $$;
-- (c) Assess only pending applications.
CREATE PROCEDURE pr_assess_application(p_application_id INT) LANGUAGE plpgsql SET search_path = ict371_q10, public AS $$
DECLARE a applications%ROWTYPE; v_status TEXT;
BEGIN
 SELECT * INTO a FROM applications WHERE application_id=p_application_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application'; END IF;
 IF a.status<>'PENDING' THEN RAISE EXCEPTION 'Application already assessed'; END IF;
 v_status:=CASE WHEN fn_scholarship_eligible(a.age_at_application,a.monthly_income,a.average_mark) THEN 'APPROVED' ELSE 'REJECTED' END;
 UPDATE applications SET status=v_status WHERE application_id=p_application_id;
END; $$;
-- (d) Actual status changes only.
CREATE FUNCTION fn_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q10, public AS $$
BEGIN
 INSERT INTO decision_audit(application_id,old_status,new_status,changed_at) VALUES(NEW.application_id,OLD.status,NEW.status,CURRENT_TIMESTAMP);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_decision_audit AFTER UPDATE ON applications FOR EACH ROW
 WHEN(OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_decision_audit();
-- (e) Approved applicants, without household income.
CREATE VIEW v_approved_applicants AS
SELECT s.student_number,s.full_name,a.average_mark,a.status FROM applications a JOIN students s USING(student_id) WHERE a.status='APPROVED';
-- (f) Composite index supports status equality and submitted_on date range.
CREATE INDEX idx_applications_status_date ON applications(status,submitted_on);
EXPLAIN ANALYZE SELECT * FROM applications WHERE status='PENDING' AND submitted_on BETWEEN CURRENT_DATE-7 AND CURRENT_DATE;
-- (g) Process pending applications using the single-application procedure.
CREATE PROCEDURE pr_assess_pending() LANGUAGE plpgsql SET search_path = ict371_q10, public AS $$
DECLARE r RECORD;
BEGIN
 FOR r IN SELECT application_id FROM applications WHERE status='PENDING' ORDER BY application_id FOR UPDATE LOOP
  CALL pr_assess_application(r.application_id);
 END LOOP;
END; $$;
-- Tests demonstrate both single and batch assessment, then an idempotent rerun.
CALL pr_assess_application(1);
CALL pr_assess_pending();
CALL pr_assess_pending();
SELECT * FROM v_approved_applicants;
SELECT * FROM applications;
SELECT * FROM decision_audit;
SELECT fn_scholarship_eligible(18,3000,70),fn_scholarship_eligible(25,3000,70),fn_scholarship_eligible(26,3000,70);

DO $$ BEGIN
 UPDATE applications SET status=status WHERE application_id=1;
 IF (SELECT COUNT(*) FROM v_approved_applicants)<>2 OR (SELECT COUNT(*) FROM applications WHERE status='REJECTED')<>4
 OR (SELECT COUNT(*) FROM decision_audit)<>6 OR EXISTS(SELECT 1 FROM applications WHERE status='PENDING')
 THEN RAISE EXCEPTION 'TEST FAILED: scholarship decisions'; END IF;
 BEGIN CALL pr_assess_application(1); RAISE EXCEPTION 'TEST FAILED: repeat assessment accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Application already assessed' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: eligibility boundaries, decision audit and idempotent batch';
END; $$;

COMMIT;

-- (g) Schedule: 0 8 * * 1. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q10_assess', '0 8 * * 1', $job$CALL ict371_q10.pr_assess_pending();$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q10_assess';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q10_assess', '0 8 * * 1', $command$CALL ict371_q10.pr_assess_pending();$command$;
    RAISE NOTICE 'Scheduled ict371_q10_assess, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
