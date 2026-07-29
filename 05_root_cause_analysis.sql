/* ============================================================
   05 - Root cause analysis
   
   Each query answers an operational question, not a generic one.
   Read the comment above each: that is the interview answer.
   ============================================================ */

USE ICQA_Analytics;
GO

/* ------------------------------------------------------------
   Q1. WHERE IN THE PROCESS IS THE TIME LOST?
   Compares stage duration for on-time vs late orders. If late
   orders differ mainly in transit, it is a carrier problem.
   If they differ in handling, it is an internal process problem.
   ------------------------------------------------------------ */
SELECT
    CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time' END AS outcome,
    COUNT(*)                                    AS orders,
    CAST(AVG(hrs_to_approve) AS DECIMAL(10,1))  AS avg_hrs_approve,
    CAST(AVG(hrs_handling)   AS DECIMAL(10,1))  AS avg_hrs_handling,
    CAST(AVG(hrs_transit)    AS DECIMAL(10,1))  AS avg_hrs_transit,
    CAST(AVG(hrs_total_cycle) AS DECIMAL(10,1)) AS avg_hrs_total
FROM analytics.fact_order_fulfillment
GROUP BY CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time' END;
GO


/* ------------------------------------------------------------
   Q2. PARETO: HOW CONCENTRATED IS THE DEFECT?
   Cumulative share of all late deliveries by seller, ranked.
   The answer to "do we fix 5 sellers or 500?"
   ------------------------------------------------------------ */
WITH seller_defects AS (
    SELECT
        seller_id,
        seller_state,
        COUNT(*)      AS orders,
        SUM(is_late)  AS late_orders
    FROM analytics.fact_order_fulfillment
    WHERE seller_id IS NOT NULL
    GROUP BY seller_id, seller_state
    HAVING COUNT(*) >= 30            -- exclude low-volume noise
),
ranked AS (
    SELECT *,
        CAST(100.0*late_orders/orders AS DECIMAL(5,2)) AS late_rate_pct,
        SUM(late_orders) OVER (ORDER BY late_orders DESC
                               ROWS UNBOUNDED PRECEDING)  AS cum_late,
        SUM(late_orders) OVER ()                          AS total_late,
        ROW_NUMBER() OVER (ORDER BY late_orders DESC)     AS seller_rank,
        COUNT(*) OVER ()                                  AS total_sellers
    FROM seller_defects
)
SELECT TOP 25
    seller_rank,
    seller_id,
    seller_state,
    orders,
    late_orders,
    late_rate_pct,
    CAST(100.0*cum_late/total_late AS DECIMAL(5,2)) AS cum_pct_of_all_defects,
    CAST(100.0*seller_rank/total_sellers AS DECIMAL(5,2)) AS pct_of_sellers
FROM ranked
ORDER BY seller_rank;
GO


/* ------------------------------------------------------------
   Q3. IS IT THE SELLER, OR IS IT THE LANE?
   Separates internal SLA misses from long-distance shipping.
   Controls the obvious confounder before blaming a hub.
   ------------------------------------------------------------ */
SELECT
    shipping_lane,
    missed_ship_sla,
    COUNT(*)                                        AS orders,
    SUM(is_late)                                    AS late_orders,
    CAST(100.0*SUM(is_late)/COUNT(*) AS DECIMAL(5,2)) AS late_rate_pct,
    CAST(AVG(hrs_handling) AS DECIMAL(10,1))        AS avg_hrs_handling,
    CAST(AVG(hrs_transit)  AS DECIMAL(10,1))        AS avg_hrs_transit
FROM analytics.fact_order_fulfillment
WHERE seller_state IS NOT NULL
GROUP BY shipping_lane, missed_ship_sla
ORDER BY shipping_lane, missed_ship_sla;
GO


/* ------------------------------------------------------------
   Q4. DEFECT TREND OVER TIME, WITH A 3-MONTH MOVING AVERAGE.
   Distinguishes a real trend from month-to-month noise.
   ------------------------------------------------------------ */
WITH monthly AS (
    SELECT
        purchase_month,
        COUNT(*)     AS orders,
        SUM(is_late) AS late_orders
    FROM analytics.fact_order_fulfillment
    GROUP BY purchase_month
)
SELECT
    purchase_month,
    orders,
    late_orders,
    CAST(100.0*late_orders/orders AS DECIMAL(5,2)) AS late_rate_pct,
    CAST(AVG(100.0*late_orders/orders) OVER (
            ORDER BY purchase_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
         ) AS DECIMAL(5,2))                        AS late_rate_3mo_avg,
    CAST(100.0*late_orders/orders
         - LAG(100.0*late_orders/orders) OVER (ORDER BY purchase_month)
         AS DECIMAL(5,2))                          AS mom_change_pts
FROM monthly
WHERE orders >= 100
ORDER BY purchase_month;
GO


/* ------------------------------------------------------------
   Q5. GEOGRAPHIC BOTTLENECK: which origin states underperform?
   Ranked against the national baseline so "bad" is relative,
   not absolute. This feeds the Tableau map.
   ------------------------------------------------------------ */

WITH state_perf AS (
    SELECT
        seller_state,
        COUNT(*)     AS orders,
        COUNT(DISTINCT seller_id) AS seller_count,
        SUM(is_late) AS late_orders,
        AVG(hrs_handling) AS avg_handling,
        AVG(hrs_transit)  AS avg_transit
    FROM analytics.fact_order_fulfillment
    WHERE seller_state IS NOT NULL
    GROUP BY seller_state
    HAVING COUNT(*) >= 100
       AND COUNT(DISTINCT seller_id) >= 10
)
SELECT
    seller_state,
    orders,
    seller_count,
    CAST(100.0*late_orders/orders AS DECIMAL(5,2))   AS late_rate_pct,
    CAST(AVG(100.0*late_orders/orders) OVER () AS DECIMAL(5,2)) AS national_avg_pct,
    CAST(100.0*late_orders/orders
         - AVG(100.0*late_orders/orders) OVER () AS DECIMAL(5,2)) AS variance_vs_national,
    CAST(avg_handling AS DECIMAL(10,1))              AS avg_hrs_handling,
    CAST(avg_transit  AS DECIMAL(10,1))              AS avg_hrs_transit,
    RANK() OVER (ORDER BY 1.0*late_orders/orders DESC) AS worst_rank
FROM state_perf
ORDER BY worst_rank;


/* ------------------------------------------------------------
   Q6. PRODUCT CATEGORY DEFECT PROFILE.
   Are heavy or bulky items driving failures? Ties physical
   handling characteristics to the defect rate.
   ------------------------------------------------------------ */
WITH cat AS (
    SELECT DISTINCT
        COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category,
        f.order_id,
        f.is_late
    FROM analytics.fact_order_fulfillment f
    JOIN raw.order_items i ON i.order_id = f.order_id
    JOIN raw.products    p ON p.product_id = i.product_id
    LEFT JOIN raw.product_category_translation t
           ON t.product_category_name = p.product_category_name
)
SELECT TOP 20 category,
    COUNT(*) AS orders,
    CAST(100.0*SUM(is_late)/COUNT(*) AS DECIMAL(5,2)) AS late_rate_pct
FROM cat
GROUP BY category
HAVING COUNT(*) >= 200
ORDER BY late_rate_pct DESC;


/* ------------------------------------------------------------
   Q7. DOES THE DEFECT COST ANYTHING?
   Links lateness to review score. Turns an ops metric into a
   business metric -- this is the slide leadership cares about.
   ------------------------------------------------------------ */
-- Is the 15+ band contaminated by bad estimated-delivery dates?
SELECT
    CASE
        WHEN is_late = 0 THEN '0 - On time or early'
        WHEN days_late = 0 THEN '1 - Same day, hours late'
        WHEN days_late BETWEEN 1 AND 3   THEN '2 - 1 to 3 days late'
        WHEN days_late BETWEEN 4 AND 7   THEN '3 - 4 to 7 days late'
        WHEN days_late BETWEEN 8 AND 14  THEN '4 - 8 to 14 days late'
        ELSE '5 - 15+ days late'
    END                                          AS lateness_band,
    COUNT(*)                                     AS orders,
    CAST(AVG(1.0*review_score) AS DECIMAL(4,2))  AS avg_review_score,
    CAST(100.0*SUM(is_detractor)/COUNT(*) AS DECIMAL(5,2)) AS detractor_rate_pct
FROM analytics.fact_order_fulfillment
WHERE review_score IS NOT NULL
GROUP BY
    CASE
        WHEN is_late = 0 THEN '0 - On time or early'
        WHEN days_late = 0 THEN '1 - Same day, hours late'
        WHEN days_late BETWEEN 1 AND 3   THEN '2 - 1 to 3 days late'
        WHEN days_late BETWEEN 4 AND 7   THEN '3 - 4 to 7 days late'
        WHEN days_late BETWEEN 8 AND 14  THEN '4 - 8 to 14 days late'
        ELSE '5 - 15+ days late'
    END
ORDER BY lateness_band;


/* ------------------------------------------------------------
   Q8. ORDER COMPLEXITY vs DEFECT RATE.
   Multi-seller, multi-line orders are the fulfillment analogue
   of a hard pick. Does complexity predict failure?
   ------------------------------------------------------------ */
SELECT
    CASE WHEN seller_count = 1 THEN 'Single' ELSE 'Multi' END AS sourcing,
    COUNT(*) AS orders_with_reviews,
    CAST(100.0*SUM(is_late)/COUNT(*) AS DECIMAL(5,2)) AS late_rate_pct,
    CAST(AVG(1.0*review_score) AS DECIMAL(4,2)) AS avg_review_score,
    CAST(100.0*SUM(is_detractor)/COUNT(*) AS DECIMAL(5,2)) AS detractor_rate_pct
FROM analytics.fact_order_fulfillment
WHERE review_score IS NOT NULL AND line_count IS NOT NULL
GROUP BY CASE WHEN seller_count = 1 THEN 'Single' ELSE 'Multi' END;


WITH state_perf AS (
    SELECT
        seller_state,
        COUNT(*)     AS orders,
        COUNT(DISTINCT seller_id) AS seller_count,
        SUM(is_late) AS late_orders,
        AVG(hrs_handling) AS avg_handling,
        AVG(hrs_transit)  AS avg_transit
    FROM analytics.fact_order_fulfillment
    WHERE seller_state IS NOT NULL
    GROUP BY seller_state
    HAVING COUNT(*) >= 100
       AND COUNT(DISTINCT seller_id) >= 10
)
SELECT
    seller_state,
    orders,
    seller_count,
    CAST(100.0*late_orders/orders AS DECIMAL(5,2))   AS late_rate_pct,
    CAST(AVG(100.0*late_orders/orders) OVER () AS DECIMAL(5,2)) AS national_avg_pct,
    CAST(100.0*late_orders/orders
         - AVG(100.0*late_orders/orders) OVER () AS DECIMAL(5,2)) AS variance_vs_national,
    CAST(avg_handling AS DECIMAL(10,1))              AS avg_hrs_handling,
    CAST(avg_transit  AS DECIMAL(10,1))              AS avg_hrs_transit,
    RANK() OVER (ORDER BY 1.0*late_orders/orders DESC) AS worst_rank
FROM state_perf
ORDER BY worst_rank;