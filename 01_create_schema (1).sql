/* ============================================================
   ICQA Fulfillment Defect & Lead-Time Variance Analyzer
   01 - Database and raw schema (SQL Server)
   Run this once in SSMS before running the Python loader.
   ============================================================ */

IF DB_ID('ICQA_Analytics') IS NULL
    CREATE DATABASE ICQA_Analytics;
GO

USE ICQA_Analytics;
GO

IF SCHEMA_ID('raw') IS NULL EXEC('CREATE SCHEMA raw');
GO

/* ---------- drop in dependency-safe order (re-runnable) ---------- */
DROP TABLE IF EXISTS raw.order_reviews;
DROP TABLE IF EXISTS raw.order_payments;
DROP TABLE IF EXISTS raw.order_items;
DROP TABLE IF EXISTS raw.orders;
DROP TABLE IF EXISTS raw.products;
DROP TABLE IF EXISTS raw.sellers;
DROP TABLE IF EXISTS raw.customers;
DROP TABLE IF EXISTS raw.geolocation;
DROP TABLE IF EXISTS raw.product_category_translation;
GO

/* ---------- customers ---------- */
CREATE TABLE raw.customers (
    customer_id                NVARCHAR(50) NOT NULL,
    customer_unique_id         NVARCHAR(50) NULL,
    customer_zip_code_prefix   NVARCHAR(10) NULL,
    customer_city              NVARCHAR(100) NULL,
    customer_state             NVARCHAR(5)  NULL
);
GO

/* ---------- sellers (proxy for "fulfillment node") ---------- */
CREATE TABLE raw.sellers (
    seller_id                  NVARCHAR(50) NOT NULL,
    seller_zip_code_prefix     NVARCHAR(10) NULL,
    seller_city                NVARCHAR(100) NULL,
    seller_state               NVARCHAR(5)  NULL
);
GO

/* ---------- products ---------- */
CREATE TABLE raw.products (
    product_id                  NVARCHAR(50) NOT NULL,
    product_category_name       NVARCHAR(100) NULL,
    product_name_lenght         INT NULL,
    product_description_lenght  INT NULL,
    product_photos_qty          INT NULL,
    product_weight_g            FLOAT NULL,
    product_length_cm           FLOAT NULL,
    product_height_cm           FLOAT NULL,
    product_width_cm            FLOAT NULL
);
GO

CREATE TABLE raw.product_category_translation (
    product_category_name          NVARCHAR(100) NULL,
    product_category_name_english  NVARCHAR(100) NULL
);
GO

/* ---------- orders: the spine of every defect metric ---------- */
CREATE TABLE raw.orders (
    order_id                       NVARCHAR(50) NOT NULL,
    customer_id                    NVARCHAR(50) NULL,
    order_status                   NVARCHAR(30) NULL,
    order_purchase_timestamp       DATETIME2 NULL,
    order_approved_at              DATETIME2 NULL,
    order_delivered_carrier_date   DATETIME2 NULL,   -- outbound handoff
    order_delivered_customer_date  DATETIME2 NULL,   -- final delivery
    order_estimated_delivery_date  DATETIME2 NULL    -- promise date
);
GO

/* ---------- order items: line-level, one row per unit ---------- */
CREATE TABLE raw.order_items (
    order_id            NVARCHAR(50) NOT NULL,
    order_item_id       INT NULL,
    product_id          NVARCHAR(50) NULL,
    seller_id           NVARCHAR(50) NULL,
    shipping_limit_date DATETIME2 NULL,              -- SLA cutoff
    price               DECIMAL(12,2) NULL,
    freight_value       DECIMAL(12,2) NULL
);
GO

/* ---------- payments ---------- */
CREATE TABLE raw.order_payments (
    order_id             NVARCHAR(50) NOT NULL,
    payment_sequential   INT NULL,
    payment_type         NVARCHAR(30) NULL,
    payment_installments INT NULL,
    payment_value        DECIMAL(12,2) NULL
);
GO

/* ---------- reviews: the customer-visible defect signal ---------- */
CREATE TABLE raw.order_reviews (
    review_id               NVARCHAR(50) NULL,
    order_id                NVARCHAR(50) NULL,
    review_score            INT NULL,
    review_comment_title    NVARCHAR(200) NULL,
    review_comment_message  NVARCHAR(MAX) NULL,      -- contains embedded newlines
    review_creation_date    DATETIME2 NULL,
    review_answer_timestamp DATETIME2 NULL
);
GO

/* ---------- geolocation (large: ~1M rows) ---------- */
CREATE TABLE raw.geolocation (
    geolocation_zip_code_prefix NVARCHAR(10) NULL,
    geolocation_lat             FLOAT NULL,
    geolocation_lng             FLOAT NULL,
    geolocation_city            NVARCHAR(100) NULL,
    geolocation_state           NVARCHAR(5) NULL
);
GO

PRINT 'Schema created. Now run 02_load_olist.py, then 03_add_keys_indexes.sql';
GO
