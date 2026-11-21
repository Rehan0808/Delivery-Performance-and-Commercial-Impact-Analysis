/* =====================================================================
   04_build_gold_views.sql
   Star-schema views for the Power BI dashboard (SQL Server / T-SQL).

   WHY: slicers mismatch when a visual reads a pre-aggregated table
   (like gold_seller_scorecard) that has no date, state or category column,
   or when dimension values differ in case, spaces or spelling.

   RULES USED HERE
   1. Facts stay at row level, so any slicer can filter them.
   2. Every dimension is built with SELECT DISTINCT from the fact,
      so a slicer value always exists in the fact (no orphans).
   3. Text keys are cleaned once (UPPER + TRIM) in the fact view.

   CHECK BEFORE RUNNING: replace these assumed names with yours
     bronze_product_category_name_translation  (columns: product_category_name, product_category_name_english)
     bronze_olist_sellers         (columns: seller_id, seller_state)
   ===================================================================== */


/* ---------- 1. FACT: one row per delivered order (grain = order_id) ---------- */
CREATE OR ALTER VIEW gold_fact_orders AS
WITH item_category AS (
    -- Primary category = category of the highest-priced item in the order.
    -- product_id breaks ties, so exactly one row per order.
    SELECT order_id, category
    FROM (
        SELECT
            bi.order_id,
            COALESCE(t.product_category_name_english,
                     bp.product_category_name, 'unknown')            AS category,
            ROW_NUMBER() OVER (PARTITION BY bi.order_id
                               ORDER BY bi.price DESC, bi.product_id) AS rn
        FROM bronze_olist_order_items bi
        LEFT JOIN bronze_olist_products bp
               ON bi.product_id = bp.product_id
        LEFT JOIN bronze_product_category_name_translation t
               ON bp.product_category_name = t.product_category_name
    ) x
    WHERE rn = 1
)
SELECT
    o.order_id,
    CAST(o.order_purchase_timestamp AS DATE)                  AS purchase_date,
    UPPER(LTRIM(RTRIM(o.customer_state)))                     AS customer_state,
    UPPER(LTRIM(RTRIM(COALESCE(ic.category, 'unknown'))))     AS category,

    o.is_late,
    CASE WHEN o.is_late = 1 THEN 'Late' ELSE 'On-time' END    AS delivery_status,

    o.review_score,
    -- Low review = score 1 or 2 (BRD definition). NULL when there is no review.
    CASE WHEN o.review_score IS NULL THEN NULL
         WHEN o.review_score <= 2    THEN 1
         ELSE 0 END                                           AS is_low_review,

    o.total_gmv,
    o.total_freight,
    o.approval_days,
    o.seller_processing_days,
    o.carrier_transit_days,
    o.deliv_delay_days,

    -- Sequential CASE (no BETWEEN), so decimal delays cannot fall into a gap.
    CASE WHEN o.deliv_delay_days <= 0  THEN 1
         WHEN o.deliv_delay_days <= 5  THEN 2
         WHEN o.deliv_delay_days <= 15 THEN 3
         ELSE 4 END                                           AS delay_band_sort,
    CASE WHEN o.deliv_delay_days <= 0  THEN 'Early / on-time'
         WHEN o.deliv_delay_days <= 5  THEN '1-5 days late'
         WHEN o.deliv_delay_days <= 15 THEN '6-15 days late'
         ELSE '16+ days late' END                             AS delay_band
FROM silver_orders o
LEFT JOIN item_category ic
       ON ic.order_id = o.order_id;
GO


/* ---------- 2. FACT: one row per order and seller (grain = order_id + seller_id) ---------- */
CREATE OR ALTER VIEW gold_fact_order_seller AS
SELECT
    os.order_id,
    os.seller_id,
    os.is_late,
    os.seller_gmv
FROM silver_order_seller os
JOIN gold_fact_orders f          -- keeps only orders that exist in the order fact
  ON f.order_id = os.order_id;
GO


/* ---------- 3. DIMENSIONS (all derived from the facts) ---------- */
CREATE OR ALTER VIEW gold_dim_state AS
SELECT DISTINCT customer_state
FROM gold_fact_orders
WHERE customer_state IS NOT NULL;
GO

CREATE OR ALTER VIEW gold_dim_category AS
SELECT DISTINCT category
FROM gold_fact_orders;
GO

CREATE OR ALTER VIEW gold_dim_seller AS
SELECT
    s.seller_id,
    ROW_NUMBER() OVER (ORDER BY s.seller_id)             AS seller_key,   -- used as Pareto tie-breaker
    UPPER(LTRIM(RTRIM(COALESCE(bs.seller_state, 'UNKNOWN')))) AS seller_state
FROM (SELECT DISTINCT seller_id FROM gold_fact_order_seller) s
LEFT JOIN bronze_olist_sellers bs
       ON bs.seller_id = s.seller_id;
GO


/* =====================================================================
   VALIDATION: run these and keep the results in your quality log.
   Every check should return the expected value shown in the comment.
   ===================================================================== */

-- A. Grain of the order fact (both numbers must be equal, and equal COUNT(*) of silver_orders)
SELECT COUNT(*) AS fact_rows, COUNT(DISTINCT order_id) AS distinct_orders FROM gold_fact_orders;
SELECT COUNT(*) AS silver_rows FROM silver_orders;

-- B. Grain of the order-seller fact (duplicates must be 0)
SELECT COUNT(*) - COUNT(DISTINCT CONCAT(order_id, '|', seller_id)) AS duplicate_rows
FROM gold_fact_order_seller;

-- C. Orphans (must be 0)
SELECT COUNT(*) AS orphan_sellers
FROM gold_fact_order_seller f
LEFT JOIN gold_dim_seller d ON d.seller_id = f.seller_id
WHERE d.seller_id IS NULL;

-- D. Unknown categories and states (small numbers are fine, but note them in the log)
SELECT COUNT(*) AS unknown_category_orders FROM gold_fact_orders WHERE category = 'UNKNOWN';
SELECT COUNT(*) AS missing_state_orders    FROM gold_fact_orders WHERE customer_state IS NULL;

-- E. Totals must match the source (difference must be 0)
SELECT
    (SELECT SUM(total_gmv) FROM silver_orders)       AS silver_gmv,
    (SELECT SUM(total_gmv) FROM gold_fact_orders)    AS fact_gmv,
    (SELECT SUM(is_late)   FROM silver_orders)       AS silver_late,
    (SELECT SUM(is_late)   FROM gold_fact_orders)    AS fact_late;

-- F. Pareto reconciliation (explains your "420 sellers" number)
--    Late orders from sellers with 20+ orders vs ALL late order-seller rows.
WITH s AS (
    SELECT seller_id, COUNT(*) AS orders, SUM(is_late) AS late
    FROM gold_fact_order_seller
    GROUP BY seller_id
)
SELECT
    SUM(CASE WHEN orders >= 20 THEN late ELSE 0 END) AS late_in_eligible_sellers,
    SUM(late)                                        AS late_in_all_sellers,
    SUM(CASE WHEN orders >= 20 THEN 1 ELSE 0 END)    AS eligible_sellers,
    COUNT(*)                                         AS all_sellers
FROM s;

-- G. Pareto with a safe running total (ROWS frame + tie-breaker),
--    to compare against the DAX result in Power BI.
WITH s AS (
    SELECT seller_id, COUNT(*) AS orders, SUM(is_late) AS late
    FROM gold_fact_order_seller
    GROUP BY seller_id
    HAVING COUNT(*) >= 20
)
SELECT TOP 10
    seller_id, orders, late,
    SUM(late) OVER (ORDER BY late DESC, seller_id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS running_late,
    ROUND(100.0 * SUM(late) OVER (ORDER BY late DESC, seller_id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(late) OVER (), 2)                                       AS cum_pct
FROM s
ORDER BY late DESC, seller_id;