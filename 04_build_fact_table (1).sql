/* ============================================================
   04 - Analytics layer: fact table at ORDER grain
   
   Decomposes total fulfillment time into four stages so a defect
   can be attributed to WHERE it happened, not just THAT it happened.
   
   Stage model (the ICQA analogue):
     purchase -> approved         = payment / order release
     approved -> carrier handoff  = internal handling  (pick, pack, stage)
     carrier  -> customer         = outbound transit
     delivered vs estimated       = promise variance   (the defect)
   
   Materialized as a table, not a view: Tableau live-connects to this
   and the DATEDIFFs would otherwise recompute on every filter click.
   ============================================================ */

USE ICQA_Analytics;
GO

IF SCHEMA_ID('analytics') IS NULL EXEC('CREATE SCHEMA analytics');
GO

DROP TABLE IF EXISTS analytics.fact_order_fulfillment;
GO

WITH order_seller AS (
    /* An order can span multiple sellers. Attribute the order to the
       seller with the LATEST shipping limit -- the binding constraint
       on whether the whole order ships on time. */
    SELECT
        i.order_id,
        i.seller_id,
        i.shipping_limit_date,
        ROW_NUMBER() OVER (
            PARTITION BY i.order_id
            ORDER BY i.shipping_limit_date DESC, i.order_item_id DESC
        ) AS rn
    FROM raw.order_items i
),
order_lines AS (
    SELECT
        order_id,
        COUNT(*)                      AS line_count,
        COUNT(DISTINCT seller_id)     AS seller_count,
        COUNT(DISTINCT product_id)    AS distinct_skus,
        SUM(price)                    AS item_value,
        SUM(freight_value)            AS freight_value
    FROM raw.order_items
    GROUP BY order_id
),
order_review AS (
    /* Keep one review per order: the most recent. */
    SELECT
        order_id,
        review_score,
        ROW_NUMBER() OVER (
            PARTITION BY order_id ORDER BY review_creation_date DESC
        ) AS rn
    FROM raw.order_reviews
    WHERE order_id IS NOT NULL
)
SELECT
    o.order_id,
    o.order_status,

    /* ---------- calendar keys ---------- */
    CAST(o.order_purchase_timestamp AS DATE)              AS purchase_date,
    DATEFROMPARTS(YEAR(o.order_purchase_timestamp),
                  MONTH(o.order_purchase_timestamp), 1)   AS purchase_month,
    DATENAME(weekday, o.order_purchase_timestamp)         AS purchase_weekday,

    /* ---------- raw timestamps ---------- */
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,

    /* ---------- stage durations, in hours ---------- */
    DATEDIFF(minute, o.order_purchase_timestamp,
                     o.order_approved_at) / 60.0          AS hrs_to_approve,
    DATEDIFF(minute, o.order_approved_at,
                     o.order_delivered_carrier_date) / 60.0 AS hrs_handling,
    DATEDIFF(minute, o.order_delivered_carrier_date,
                     o.order_delivered_customer_date) / 60.0 AS hrs_transit,
    DATEDIFF(minute, o.order_purchase_timestamp,
                     o.order_delivered_customer_date) / 60.0 AS hrs_total_cycle,

    /* ---------- the defect ---------- */
    DATEDIFF(day, o.order_estimated_delivery_date,
                  o.order_delivered_customer_date)        AS days_late,
    CASE WHEN o.order_delivered_customer_date
              > o.order_estimated_delivery_date
         THEN 1 ELSE 0 END                                AS is_late,

    /* SLA breach at the handling stage: did the seller miss the
       shipping cutoff? This is the internal-process defect. */
    CASE WHEN o.order_delivered_carrier_date
              > os.shipping_limit_date
         THEN 1 ELSE 0 END                                AS missed_ship_sla,

    /* ---------- attribution ---------- */
    os.seller_id,
    s.seller_state,
    s.seller_city,
    c.customer_state,
    CASE WHEN s.seller_state = c.customer_state
         THEN 'Intra-state' ELSE 'Inter-state' END        AS shipping_lane,

    /* ---------- order composition ---------- */
    ol.line_count,
    ol.seller_count,
    ol.distinct_skus,
    ol.item_value,
    ol.freight_value,

    /* ---------- customer-visible outcome ---------- */
    r.review_score,
    CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END       AS is_detractor

INTO analytics.fact_order_fulfillment
FROM raw.orders o
LEFT JOIN order_seller os ON os.order_id = o.order_id AND os.rn = 1
LEFT JOIN raw.sellers  s  ON s.seller_id = os.seller_id
LEFT JOIN raw.customers c ON c.customer_id = o.customer_id
LEFT JOIN order_lines  ol ON ol.order_id = o.order_id
LEFT JOIN order_review r  ON r.order_id = o.order_id AND r.rn = 1
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;
GO

CREATE CLUSTERED INDEX IX_fact_purchase_date
    ON analytics.fact_order_fulfillment (purchase_date);
CREATE INDEX IX_fact_seller  ON analytics.fact_order_fulfillment (seller_id);
CREATE INDEX IX_fact_late    ON analytics.fact_order_fulfillment (is_late);
CREATE INDEX IX_fact_state   ON analytics.fact_order_fulfillment (seller_state);
GO

/* ---------- validate ---------- */
SELECT
    COUNT(*)                                   AS fact_rows,
    SUM(is_late)                               AS late_orders,
    CAST(100.0*SUM(is_late)/COUNT(*) AS DECIMAL(5,2)) AS late_rate_pct,
    SUM(missed_ship_sla)                       AS missed_ship_sla,
    SUM(CASE WHEN seller_id IS NULL THEN 1 ELSE 0 END) AS unattributed
FROM analytics.fact_order_fulfillment;
GO
-- late_rate_pct should land at ~8.11, matching script 03.
