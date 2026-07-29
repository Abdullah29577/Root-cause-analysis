/* ============================================================
   03 - Validation, keys, indexes
   Run AFTER 02_load_olist.py completes.
   ============================================================ */

USE ICQA_Analytics;
GO

/* ---------- 1. Row-count validation vs. published Olist counts ---------- */
SELECT 'orders'        AS table_name, COUNT(*) AS actual_rows, 99441   AS expected_rows FROM raw.orders
UNION ALL SELECT 'order_items',   COUNT(*), 112650  FROM raw.order_items
UNION ALL SELECT 'order_payments',COUNT(*), 103886  FROM raw.order_payments
UNION ALL SELECT 'order_reviews', COUNT(*), 99224   FROM raw.order_reviews
UNION ALL SELECT 'customers',     COUNT(*), 99441   FROM raw.customers
UNION ALL SELECT 'products',      COUNT(*), 32951   FROM raw.products
UNION ALL SELECT 'sellers',       COUNT(*), 3095    FROM raw.sellers
UNION ALL SELECT 'geolocation',   COUNT(*), 1000163 FROM raw.geolocation;
GO
-- If order_reviews is short, the CSV parse shifted columns. Re-run the loader.

/* ---------- 2. Did the datetimes land as real datetimes? ---------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'raw' AND TABLE_NAME = 'orders';
GO
-- All five *_date / *_timestamp columns must read datetime2, not nvarchar.

/* ---------- 3. Referential sanity: orphan items ---------- */
SELECT COUNT(*) AS orphan_order_items
FROM raw.order_items i
LEFT JOIN raw.orders o ON o.order_id = i.order_id
WHERE o.order_id IS NULL;
GO
-- Expect 0.

/* ---------- 4. Keys ---------- */
ALTER TABLE raw.orders    ALTER COLUMN order_id    NVARCHAR(50) NOT NULL;
ALTER TABLE raw.customers ALTER COLUMN customer_id NVARCHAR(50) NOT NULL;
ALTER TABLE raw.products  ALTER COLUMN product_id  NVARCHAR(50) NOT NULL;
ALTER TABLE raw.sellers   ALTER COLUMN seller_id   NVARCHAR(50) NOT NULL;
GO

ALTER TABLE raw.orders    ADD CONSTRAINT PK_orders    PRIMARY KEY (order_id);
ALTER TABLE raw.customers ADD CONSTRAINT PK_customers PRIMARY KEY (customer_id);
ALTER TABLE raw.products  ADD CONSTRAINT PK_products  PRIMARY KEY (product_id);
ALTER TABLE raw.sellers   ADD CONSTRAINT PK_sellers   PRIMARY KEY (seller_id);
GO

/* ---------- 5. Indexes for the joins you will run constantly ---------- */
CREATE INDEX IX_order_items_order   ON raw.order_items (order_id);
CREATE INDEX IX_order_items_seller  ON raw.order_items (seller_id);
CREATE INDEX IX_order_items_product ON raw.order_items (product_id);
CREATE INDEX IX_reviews_order       ON raw.order_reviews (order_id);
CREATE INDEX IX_payments_order      ON raw.order_payments (order_id);
CREATE INDEX IX_orders_purchase     ON raw.orders (order_purchase_timestamp);
CREATE INDEX IX_orders_status       ON raw.orders (order_status);
CREATE INDEX IX_geo_zip             ON raw.geolocation (geolocation_zip_code_prefix);
GO

/* ---------- 6. First look at the defect signal ---------- */
SELECT
    order_status,
    COUNT(*) AS orders,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_total
FROM raw.orders
GROUP BY order_status
ORDER BY orders DESC;
GO

/* Late-delivery rate: the headline ICQA-analogous defect metric */
SELECT
    COUNT(*) AS delivered_orders,
    SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date
             THEN 1 ELSE 0 END) AS late_deliveries,
    CAST(100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date
             THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS late_rate_pct
FROM raw.orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;
GO
