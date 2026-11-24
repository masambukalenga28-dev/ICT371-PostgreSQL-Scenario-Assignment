-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- PostgreSQL 11+; run once in pgAdmin. Each question has a separate schema.
-- No existing tables are dropped. To rerun, use a fresh database/schema.
BEGIN;
CREATE SCHEMA ict371_q05;
SET search_path TO ict371_q05, public;

-- (a) Tables
CREATE TABLE students(student_id SERIAL PRIMARY KEY,student_number TEXT UNIQUE NOT NULL,full_name TEXT NOT NULL);
CREATE TABLE rooms(room_id SERIAL PRIMARY KEY,room_number TEXT UNIQUE NOT NULL,capacity INT NOT NULL CHECK(capacity>0));
CREATE TABLE allocations(
 allocation_id SERIAL PRIMARY KEY,student_id INT NOT NULL REFERENCES students,room_id INT NOT NULL REFERENCES rooms,
 allocated_on DATE NOT NULL,released_on DATE,status TEXT NOT NULL CHECK(status IN('ACTIVE','ENDED')),
 CHECK((status='ACTIVE' AND released_on IS NULL) OR (status='ENDED' AND released_on IS NOT NULL)),
 CHECK(released_on>=allocated_on)
);
CREATE UNIQUE INDEX uq_one_active_student ON allocations(student_id) WHERE status='ACTIVE';
CREATE TABLE occupancy_snapshot(snapshot_date DATE NOT NULL,room_id INT NOT NULL REFERENCES rooms,
 occupied_beds INT NOT NULL CHECK(occupied_beds>=0),free_beds INT NOT NULL CHECK(free_beds>=0),PRIMARY KEY(snapshot_date,room_id));
INSERT INTO students(student_number,full_name) VALUES('S001','Alice'),('S002','Brian'),('S003','Chanda'),('S004','David'),('S005','Esther');
INSERT INTO rooms(room_number,capacity) VALUES('A01',2),('A02',3),('A03',2);
-- (b) Function
CREATE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT LANGUAGE plpgsql SET search_path = ict371_q05, public AS $$
DECLARE v_capacity INT;
BEGIN
 SELECT capacity INTO v_capacity FROM rooms WHERE room_id=p_room_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room'; END IF;
 RETURN v_capacity-(SELECT COUNT(*)::INT FROM allocations WHERE room_id=p_room_id AND status='ACTIVE');
END; $$;
-- (c) Procedure
CREATE PROCEDURE pr_allocate_room(p_student_id INT,p_room_id INT,p_allocated_on DATE) LANGUAGE plpgsql SET search_path = ict371_q05, public AS $$
BEGIN
 PERFORM 1 FROM students WHERE student_id=p_student_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student'; END IF;
 PERFORM 1 FROM rooms WHERE room_id=p_room_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room'; END IF;
 IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date required'; END IF;
 IF EXISTS(SELECT 1 FROM allocations WHERE student_id=p_student_id AND status='ACTIVE') THEN RAISE EXCEPTION 'Student already allocated'; END IF;
 IF fn_free_beds(p_room_id)<=0 THEN RAISE EXCEPTION 'Room is full'; END IF;
 INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status) VALUES(p_student_id,p_room_id,p_allocated_on,NULL,'ACTIVE');
END; $$;
-- (d) Trigger: direct changes also check capacity and student; exclude updated row.
CREATE FUNCTION fn_validate_allocation() RETURNS TRIGGER LANGUAGE plpgsql SET search_path = ict371_q05, public AS $$
DECLARE v_capacity INT; v_exclude INT;
BEGIN
 IF NEW.status<>'ACTIVE' THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' THEN v_exclude:=OLD.allocation_id; END IF;
 PERFORM 1 FROM students WHERE student_id=NEW.student_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student'; END IF;
 SELECT capacity INTO v_capacity FROM rooms WHERE room_id=NEW.room_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room'; END IF;
 IF EXISTS(SELECT 1 FROM allocations a WHERE a.student_id=NEW.student_id AND a.status='ACTIVE' AND (v_exclude IS NULL OR a.allocation_id<>v_exclude))
 THEN RAISE EXCEPTION 'Student already allocated'; END IF;
 IF (SELECT COUNT(*) FROM allocations a WHERE a.room_id=NEW.room_id AND a.status='ACTIVE' AND (v_exclude IS NULL OR a.allocation_id<>v_exclude))>=v_capacity
 THEN RAISE EXCEPTION 'Room is full'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_validate_allocation BEFORE INSERT OR UPDATE ON allocations FOR EACH ROW EXECUTE FUNCTION fn_validate_allocation();
CALL pr_allocate_room(1,1,CURRENT_DATE-5);
CALL pr_allocate_room(2,1,CURRENT_DATE-4);
CALL pr_allocate_room(3,2,CURRENT_DATE-3);
INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status) VALUES(4,3,CURRENT_DATE-10,CURRENT_DATE-2,'ENDED');
-- (e) View: LEFT JOIN preserves empty rooms; ended allocations not counted.
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,r.room_number,r.capacity,COUNT(a.allocation_id)::INT AS occupied_beds,
 r.capacity-COUNT(a.allocation_id)::INT AS free_beds
FROM rooms r LEFT JOIN allocations a ON a.room_id=r.room_id AND a.status='ACTIVE'
GROUP BY r.room_id,r.room_number,r.capacity;
SELECT * FROM v_room_occupancy;
-- (f) Partial index indexes active allocations only, allowing efficient room lookup.
CREATE INDEX idx_active_room ON allocations(room_id) WHERE status='ACTIVE';
EXPLAIN ANALYZE SELECT * FROM allocations WHERE room_id=1 AND status='ACTIVE';
-- (g) Snapshot one row per date/room; replace on repeat.
CREATE PROCEDURE pr_refresh_occupancy() LANGUAGE plpgsql SET search_path = ict371_q05, public AS $$
BEGIN
 INSERT INTO occupancy_snapshot(snapshot_date,room_id,occupied_beds,free_beds)
 SELECT CURRENT_DATE,room_id,occupied_beds,free_beds FROM v_room_occupancy
 ON CONFLICT(snapshot_date,room_id) DO UPDATE SET occupied_beds=EXCLUDED.occupied_beds,free_beds=EXCLUDED.free_beds;
END; $$;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;
SELECT fn_free_beds(1),fn_free_beds(2),fn_free_beds(3);

DO $$ BEGIN
 UPDATE allocations SET status=status WHERE allocation_id=1;
 IF fn_free_beds(1)<>0 OR fn_free_beds(2)<>2 OR fn_free_beds(3)<>2 OR (SELECT COUNT(*) FROM occupancy_snapshot)<>3
 THEN RAISE EXCEPTION 'TEST FAILED: occupancy'; END IF;
 BEGIN INSERT INTO allocations(student_id,room_id,allocated_on,status) VALUES(5,1,CURRENT_DATE,'ACTIVE'); RAISE EXCEPTION 'TEST FAILED: full room accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Room is full' THEN RAISE; END IF; END;
 BEGIN INSERT INTO allocations(student_id,room_id,allocated_on,status) VALUES(1,2,CURRENT_DATE,'ACTIVE'); RAISE EXCEPTION 'TEST FAILED: duplicate allocation';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Student already allocated' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: occupancy, direct SQL validation and snapshot';
END; $$;

COMMIT;

-- (g) Schedule: 55 23 * * *. Requires pg_cron installed/preloaded and configured.
-- Scheduler timezone must match the intended local time (Africa/Lusaka).
-- If the automatic attempt warns, configure pg_cron and run these commands:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('ict371_q05_occupancy', '55 23 * * *', $job$CALL ict371_q05.pr_refresh_occupancy();$job$);
-- SELECT * FROM cron.job WHERE jobname = 'ict371_q05_occupancy';

DO $scheduler$
DECLARE v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job_id
        USING 'ict371_q05_occupancy', '55 23 * * *', $command$CALL ict371_q05.pr_refresh_occupancy();$command$;
    RAISE NOTICE 'Scheduled ict371_q05_occupancy, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and run the commented commands.', SQLERRM;
END;
$scheduler$;
