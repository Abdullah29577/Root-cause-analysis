/* ============================================================
   06 - Line-grain fact table for Power BI
   
   The order-grain fact can't support product/category analysis
   because products live at line grain. This second fact hangs
   off the same Date and Seller dimensions in the model.
   
   Run this before opening Power BI so both facts import together.
   ============================================================ */

USE ICQA_Analytics;
GO

DROP TABLE IF EXISTS analytics.fact_order_lines;
GO

SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    f.purchase_date,
    f.is_late,
    f.missed_ship_sla,
    f.shipping_lane,
    COALESCE(t.product_category_name_english,
             p.product_category_name, 'unknown')          AS category_en,
    p.product_weight_g / 1000.0                           AS weight_kg,
    (p.product_length_cm * p.product_height_cm
        * p.product_width_cm) / 1000.0                    AS volume_litres,
    i.price,
    i.freight_value
INTO analytics.fact_order_lines
FROM raw.order_items i
JOIN analytics.fact_order_fulfillment f ON f.order_id = i.order_id
LEFT JOIN raw.products p ON p.product_id = i.product_id
LEFT JOIN raw.product_category_translation t
       ON t.product_category_name = p.product_category_name;
GO

CREATE CLUSTERED INDEX IX_lines_date ON analytics.fact_order_lines (purchase_date);
CREATE INDEX IX_lines_cat    ON analytics.fact_order_lines (category_en);
CREATE INDEX IX_lines_seller ON analytics.fact_order_lines (seller_id);
GO

/* ---------- validate ---------- */
SELECT
    COUNT(*)                          AS line_rows,
    COUNT(DISTINCT order_id)          AS distinct_orders,
    COUNT(DISTINCT category_en)       AS categories,
    SUM(CASE WHEN category_en = 'unknown' THEN 1 ELSE 0 END) AS unknown_category
FROM analytics.fact_order_lines;
GO
-- distinct_orders should be 96,470 (matches the order-grain fact).
-- line_rows will be higher -- multi-line orders contribute several rows.
