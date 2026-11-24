-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales
-- PostgreSQL | Run in a fresh database (public schema).
-- Sections (a)-(g) and verification queries are included.

SET search_path TO public;

BEGIN;

-- (a) Database and seed data [6 marks]
CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty BIGINT NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(14,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES ('Paracetamol', 10.00, 50),
       ('Amoxicillin', 25.00, 30),
       ('Vitamin C', 15.00, 20);
-- Six sales are loaded through the procedure after the trigger is installed.

-- (b) Function [6 marks]
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER, p_quantity INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine not found';
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock INTEGER;
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity';
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- Lock the medicine row to serialize concurrent sales of this medicine.
    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine not found';
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock';
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger [8 marks]
CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty,
                CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();

-- (a) Continued: load six valid sales through the completed procedure.
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 12, CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(3, 8, CURRENT_DATE - 1);
CALL pr_record_sale(3, 5, CURRENT_DATE - 1);

-- (e) View [5 marks]
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- (f) Index [5 marks]
-- Justification: medicine_id is the equality filter and sold_on is the
-- range filter. This column order allows a B-tree index to efficiently
-- locate a given medicine's sales within the requested date interval.
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

-- (g) Scheduled job: summary procedure [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Summary date is required';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Refresh twice: the second run replaces the existing date's totals.
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);

COMMIT;

-- Required queries and verification
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;
SELECT fn_sale_value(1, 5) AS sale_value; -- Expected: 50.00
SELECT * FROM v_low_stock ORDER BY medicine_name;
-- Expected low stock: Amoxicillin (8), Vitamin C (7).

-- Matching query and its EXPLAIN plan.
-- Small tables can legitimately use a sequential scan despite the index.
EXPLAIN ANALYZE
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

SELECT * FROM daily_sales ORDER BY sales_date;
-- Expected for yesterday: 50 units, K895.00, one summary row.

-- Verification: expected exceptions are caught, so the script can continue.
DO $$
DECLARE
    v_sales BIGINT;
    v_audits BIGINT;
    v_stock INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_sales FROM sales;
    SELECT COUNT(*) INTO v_audits FROM stock_audit;
    SELECT stock_qty INTO v_stock FROM medicines WHERE medicine_id = 1;

    BEGIN
        CALL pr_record_sale(1, 1000, CURRENT_DATE);
        RAISE EXCEPTION 'TEST FAILED: overselling was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Insufficient stock' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM fn_sale_value(1, -5);
        RAISE EXCEPTION 'TEST FAILED: invalid quantity was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Quantity must be positive' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM fn_sale_value(-1, 1);
        RAISE EXCEPTION 'TEST FAILED: unknown medicine was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Medicine not found' THEN RAISE; END IF;
    END;

    UPDATE medicines SET stock_qty = stock_qty WHERE medicine_id = 1;

    IF (SELECT COUNT(*) FROM sales) <> v_sales
       OR (SELECT COUNT(*) FROM stock_audit) <> v_audits
       OR (SELECT stock_qty FROM medicines WHERE medicine_id = 1) <> v_stock
    THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected sale, audit or stock change';
    END IF;

    IF v_sales <> 6 OR v_audits <> 6
       OR NOT EXISTS (
           SELECT 1 FROM daily_sales
           WHERE sales_date = CURRENT_DATE - 1
             AND total_qty = 50 AND total_amount = 895.00
       ) THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected seed or summary totals';
    END IF;
    RAISE NOTICE 'PASS: validation, unchanged stock audit, six sales and daily summary';
END;
$$;

-- (g) Continued: schedule at 00:15 every day for the previous day.
-- pg_cron must be installed, preloaded and configured for this database.
-- The configured cron timezone determines when the job runs.
-- Equivalent SQL when pg_cron is available:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('daily_pharmacy_sales', '15 0 * * *',
--     $$CALL public.pr_refresh_sales(CURRENT_DATE - 1);$$);
-- SELECT * FROM cron.job WHERE jobname = 'daily_pharmacy_sales';

-- Attempt registration without losing the completed database work on
-- servers where the scheduler is not installed or permission is denied.
DO $scheduler$
DECLARE
    v_job_id BIGINT;
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    EXECUTE 'SELECT cron.schedule($1, $2, $3)'
        INTO v_job_id
        USING 'daily_pharmacy_sales', '15 0 * * *',
              'CALL public.pr_refresh_sales(CURRENT_DATE - 1);';
    RAISE NOTICE 'Scheduled daily_pharmacy_sales, job ID: %', v_job_id;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron job NOT registered: %. Configure pg_cron and rerun the scheduling commands above.', SQLERRM;
END;
$scheduler$;
