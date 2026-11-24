-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q06;
SET search_path TO ict371_q06, public;

-- (a) Tables and seed employees
CREATE TABLE employees(employee_id SERIAL PRIMARY KEY,full_name TEXT NOT NULL,
 basic_salary NUMERIC(12,2) NOT NULL CHECK(basic_salary>=0),allowance NUMERIC(12,2) NOT NULL CHECK(allowance>=0),
 deduction NUMERIC(12,2) NOT NULL CHECK(deduction>=0),active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE payroll(payroll_id SERIAL PRIMARY KEY,employee_id INT NOT NULL REFERENCES employees,
 pay_month DATE NOT NULL CHECK(EXTRACT(DAY FROM pay_month)=1),gross_pay NUMERIC(14,2) NOT NULL CHECK(gross_pay>=0),
 net_pay NUMERIC(14,2) NOT NULL CHECK(net_pay>=0),UNIQUE(employee_id,pay_month));
CREATE TABLE salary_audit(audit_id SERIAL PRIMARY KEY,employee_id INT NOT NULL REFERENCES employees,
 old_salary NUMERIC(12,2) NOT NULL,new_salary NUMERIC(12,2) NOT NULL,changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);
INSERT INTO employees(full_name,basic_salary,allowance,deduction,active) VALUES
 ('Alice Banda',5000,500,300,TRUE),('Brian Phiri',4000,400,200,TRUE),('Chanda Zulu',6000,600,500,TRUE),('David Mwale',3000,200,100,FALSE);
-- (b) Function
CREATE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC LANGUAGE plpgsql SET search_path = ict371_q06, public AS $$
DECLARE v_net NUMERIC;
BEGIN
 SELECT basic_salary+allowance-deduction INTO v_net FROM employees WHERE employee_id=p_employee_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee'; END IF;
 IF v_net<0 THEN RAISE EXCEPTION 'Negative net pay'; END IF;
 RETURN v_net;
END; $$;
-- (c) Process active employees with a query FOR loop; never overwrite historical payroll.
CREATE PROCEDURE pr_process_payroll(p_month DATE) LANGUAGE plpgsql SET search_path = ict371_q06, public AS $$
DECLARE e RECORD; v_net NUMERIC;
BEGIN
 IF p_month IS NULL OR EXTRACT(DAY FROM p_month)<>1 THEN RAISE EXCEPTION 'Month-start date required'; END IF;
 FOR e IN SELECT employee_id,basic_salary,allowance FROM employees WHERE active ORDER BY employee_id FOR SHARE LOOP
  IF NOT EXISTS(SELECT 1 FROM payroll WHERE employee_id=e.employee_id AND pay_month=p_month) THEN
   v_net:=fn_net_pay(e.employee_id);
   INSERT INTO payroll(employee_id,pay_month,gross_pay,net_pay) VALUES(e.employee_id,p_month,e.basic_salary+e.allowance,v_net)
   ON CONFLICT(employee_id,pay_month) DO NOTHING;
  END IF;
 END LOOP;
 -- No internal COMMIT: any invalid calculation rolls back this entire call.
END; $$;
-- (d) Trigger
CREATE FUNCTION fn_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q06, public AS $$
BEGIN
 INSERT INTO salary_audit(employee_id,old_salary,new_salary,changed_at) VALUES(NEW.employee_id,OLD.basic_salary,NEW.basic_salary,CURRENT_TIMESTAMP);
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_salary_audit AFTER UPDATE ON employees FOR EACH ROW
 WHEN(OLD.basic_salary IS DISTINCT FROM NEW.basic_salary) EXECUTE FUNCTION fn_salary_audit();
-- (a) continued: two months, one employee becomes inactive after historical processing.
CALL pr_process_payroll((date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE);
UPDATE employees SET basic_salary=5500 WHERE employee_id=1;
UPDATE employees SET active=FALSE WHERE employee_id=3;
CALL pr_process_payroll((date_trunc('month',CURRENT_DATE)-INTERVAL '1 month')::DATE);
CALL pr_process_payroll((date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE);
-- (e) View: no filter on employee active state; historical data remains visible.
CREATE VIEW v_payroll_report AS
SELECT e.full_name,p.pay_month,p.gross_pay,p.net_pay FROM payroll p JOIN employees e USING(employee_id);
SELECT * FROM v_payroll_report ORDER BY pay_month,full_name;
-- (f) Month-leading index supports reports across all employees; the existing unique index leads with employee_id.
CREATE INDEX idx_payroll_month ON payroll(pay_month);
EXPLAIN ANALYZE SELECT * FROM payroll WHERE pay_month=(date_trunc('month',CURRENT_DATE)-INTERVAL '1 month')::DATE;
-- (g) Scheduler below runs 02:00 on the first day of each month, for the previous month.
SELECT fn_net_pay(1);
SELECT * FROM salary_audit;

DO $$ BEGIN
 UPDATE employees SET basic_salary=basic_salary WHERE employee_id=1;
 IF fn_net_pay(1)<>5700 OR (SELECT COUNT(*) FROM salary_audit)<>1 OR (SELECT COUNT(*) FROM payroll)<>5
 OR NOT EXISTS(SELECT 1 FROM payroll WHERE employee_id=1 AND pay_month=(date_trunc('month',CURRENT_DATE)-INTERVAL '2 months')::DATE AND net_pay=5200)
 THEN RAISE EXCEPTION 'TEST FAILED: payroll history'; END IF;
 BEGIN
  UPDATE employees SET deduction=99999 WHERE employee_id=2;
  CALL pr_process_payroll(date_trunc('month',CURRENT_DATE)::DATE);
  RAISE EXCEPTION 'TEST FAILED: negative net accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Negative net pay' THEN RAISE; END IF; END;
 IF EXISTS(SELECT 1 FROM payroll WHERE pay_month=date_trunc('month',CURRENT_DATE)::DATE) THEN RAISE EXCEPTION 'TEST FAILED: partial payroll'; END IF;
 RAISE NOTICE 'PASS: history, salary audit and atomic payroll failure';
END; $$;

COMMIT;

-- (g) Schedule: 0 2 1 * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q06_payroll', '0 2 1 * *', $job$CALL ict371_q06.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q06_payroll';
-- SELECT d.* FROM cron.job_run_details d JOIN cron.job j USING (jobid)
-- WHERE j.jobname = 'ict371_q06_payroll' ORDER BY d.start_time DESC;

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q06_payroll', '0 2 1 * *', $command$CALL ict371_q06.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$command$;
    RAISE NOTICE 'Scheduled ict371_q06_payroll, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;

DO $history$
DECLARE r RECORD;
BEGIN
    IF to_regclass('cron.job') IS NOT NULL THEN
        FOR r IN EXECUTE 'SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = $1' USING 'ict371_q06_payroll' LOOP
            RAISE NOTICE 'Job: %', row_to_json(r);
        END LOOP;
    END IF;
    IF to_regclass('cron.job_run_details') IS NOT NULL THEN
        FOR r IN EXECUTE 'SELECT d.* FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = $1 ORDER BY d.start_time DESC LIMIT 10' USING 'ict371_q06_payroll' LOOP
            RAISE NOTICE 'Run: %', row_to_json(r);
        END LOOP;
    END IF;
EXCEPTION WHEN OTHERS THEN RAISE WARNING 'Job inspection unavailable: %', SQLERRM;
END;
$history$;
