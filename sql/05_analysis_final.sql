/* =====================================================================
   05_analysis_final.sql
   Olist Delivery Performance & Commercial Impact Analysis
   One section per BRD business question. Each section has:
   question, stakeholder and decision, query, then insight text.

   BEFORE RUNNING
   1. 03_build_silver.sql and 04_build_gold_views.sql have been run (creates silver_orders, gold_fact_orders etc).
   2. Late flag is date based: delivered date later than estimated date.
      Expected: 6,534 late orders out of 96,470 delivered orders (6.77%).
        CASE WHEN CAST(order_delivered_customer_date AS DATE)
                  > CAST(order_estimated_delivery_date AS DATE)
             THEN 1 ELSE 0 END AS is_late

   Wording rule: "associated with", never "caused".
   Definitions: Late = delivered date later than estimated date.
                Low review = score 1 or 2.
                Eligible seller = 20 or more orders.
                GMV = item price only (freight is a separate column). Q4d shows the BRD
                definition (price plus freight) as a cross-check.
   Numbers in the insight blocks come from the results of this file and the Python notebook.
   Status: all insight numbers are filled. Nothing is left to fill before publishing.
   ===================================================================== */


/* =====================================================================
   Q0. DATA CHECKS (keep the results in your quality log)
   ===================================================================== */

-- Q0a. Row count (expect 96,470) and late orders (expect 6,534)
SELECT COUNT(*) AS delivered_orders, SUM(is_late) AS late_orders
FROM silver_orders;

-- Q0b. is_late and delay days must agree (expect 0)
SELECT COUNT(*) AS mismatches
FROM silver_orders
WHERE (deliv_delay_days > 0 AND is_late = 0)
   OR (deliv_delay_days <= 0 AND is_late = 1);

-- Q0c. Order-seller late rows (expect 6,547)
SELECT SUM(is_late) AS late_seller_rows FROM silver_order_seller;

-- Q0d. Silver and gold must agree (compare with Q0a and Q0c)
SELECT (SELECT SUM(is_late) FROM gold_fact_orders)       AS fact_late_orders,
       (SELECT SUM(is_late) FROM gold_fact_order_seller) AS fact_late_seller_rows;

/*
Result: 96,470 delivered orders, 6,534 late (6.77%). Mismatches: 0.
        Order-seller late rows: 6,547 (an order with two sellers counts once per seller).
Data quality note: 1,292 orders delivered on the due day (delay = 0) were flagged late in the
        first version because the estimated date is stored at midnight. The flag is now
        date based, so is_late and delay days agree.
*/


/* =====================================================================
   Q1. WHERE DO DELIVERY DELAYS OCCUR?   (BRD core question 1, objective O2)
   Compare approval time, seller processing time and carrier transit time
   for late and on-time orders, and see which stage differs most.
   Check promise accuracy (actual vs estimated date) separately.
   Stakeholders: Head of Operations, Logistics Manager
   Decision: which stage to fix first
   ===================================================================== */

-- Q1a. Stage times, late vs on-time
SELECT
    is_late,
    COUNT(*)                                              AS orders,
    ROUND(AVG(CAST(approval_days AS FLOAT)), 2)           AS avg_approval_days,
    ROUND(AVG(CAST(seller_processing_days AS FLOAT)), 2)  AS avg_seller_days,
    ROUND(AVG(CAST(carrier_transit_days AS FLOAT)), 2)    AS avg_carrier_days
FROM silver_orders
GROUP BY is_late
ORDER BY is_late;

-- Q1b. Promise accuracy (separate from the stages)
-- Negative delay means delivered before the estimated date.
SELECT
    is_late,
    COUNT(*)                                                           AS orders,
    ROUND(AVG(CAST(deliv_delay_days AS FLOAT)), 2)                     AS avg_delay_vs_promise_days,
    ROUND(100.0 * SUM(CASE WHEN deliv_delay_days < 0 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                               AS pct_delivered_before_promise
FROM silver_orders
GROUP BY is_late
ORDER BY is_late;

/*
Insight: Carrier transit is the stage that differs most between late and on-time orders.
Evidence: Average carrier transit rises from 7.93 days (on-time) to 27.87 days (late), a gap of about 20 days.
          Seller processing rises from 2.50 to 5.43 days (about 3 days).
          Approval is almost the same (0.51 vs 0.61 days).
Promise accuracy: on-time orders arrive on average 13.51 days before the estimated date
          (98.56% arrive before it); late orders arrive 10.62 days after it.
Recommendation (Logistics Manager): focus carrier reviews and renegotiation on transit time first.
          Seller Management can add a second, smaller target on seller processing time.
Estimated impact (hypothetical): a 1-point fall in the late rate is associated with about
          965 fewer late orders (see Q4c).
*/


/* =====================================================================
   Q2. HOW ARE DELAYS ASSOCIATED WITH CUSTOMER SATISFACTION?
   (BRD core question 2, objective O3)
   Average review score and low-review rate, by delay band.
   Low review = score 1 or 2 (BRD definition).
   Stakeholder: Customer Experience Lead
   Decision: where to prevent bad reviews
   ===================================================================== */
SELECT
    CASE WHEN deliv_delay_days <= 0  THEN '1. Early/On-time'
         WHEN deliv_delay_days <= 5  THEN '2. 1-5 days late'
         WHEN deliv_delay_days <= 15 THEN '3. 6-15 days late'
         ELSE                             '4. 16+ days late'
    END                                                              AS delay_band,
    COUNT(*)                                                         AS orders,
    ROUND(AVG(CAST(review_score AS FLOAT)), 2)                       AS avg_review_score,
    SUM(CASE WHEN review_score = 1 THEN 1 ELSE 0 END)                AS one_star_count,
    SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END)                AS five_star_count,
    ROUND(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
          / COUNT(review_score), 2)                                  AS low_review_pct,
    ROUND(100.0 * SUM(CASE WHEN review_score = 1 THEN 1 ELSE 0 END)
          / COUNT(review_score), 2)                                  AS one_star_pct,
    ROUND(100.0 * SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END)
          / COUNT(review_score), 2)                                  AS five_star_pct
FROM silver_orders
GROUP BY
    CASE WHEN deliv_delay_days <= 0  THEN '1. Early/On-time'
         WHEN deliv_delay_days <= 5  THEN '2. 1-5 days late'
         WHEN deliv_delay_days <= 15 THEN '3. 6-15 days late'
         ELSE                             '4. 16+ days late'
    END
ORDER BY delay_band;

/*
Insight: Longer delays are associated with lower review scores and a higher low-review rate.
         The low-review rate jumps in the first 5 days of delay and levels off at about 78% after that.
Evidence: Early/on-time: avg score 4.29, low-review rate 9.28% (89,936 orders).
          1-5 days late: avg score 2.99, low-review rate 41.15% (2,770 orders).
          6-15 days late: avg score 1.74, low-review rate 78.22% (2,539 orders).
          16+ days late: avg score 1.73, low-review rate 78.31% (1,225 orders).
          Two-proportion z-test (Python, late vs on-time, low review = score 1 or 2): p < 1e-300 (effectively zero), z-test run in Python (FR7).
Recommendation (Customer Experience Lead): contact customers proactively once an order passes its
          estimated date, because most of the drop appears within the first 5 days.
Estimated impact: 3,764 orders are 6+ days late, with about 78% low reviews. See Q4 for GMV.
Limit: this is an association. Category, price and region may also play a part (see FR8).
*/


/* =====================================================================
   Q3. WHICH SELLERS NEED ATTENTION?   (BRD core question 3, objective O5)
   Rank sellers with a minimum order volume (20 orders) and use a Pareto view
   to show how concentrated late orders are. Category ranking is in S2.
   Stakeholder: Seller Management
   Decision: which sellers to coach, warn or remove
   Grain: order-seller (an order with two sellers counts once per seller)
   ===================================================================== */

-- Q3a. Seller Pareto: running total with a safe ROWS frame and a tie-breaker
;WITH lateSeller AS (
    SELECT
        seller_id,
        COUNT(*)                                       AS total_orders,
        SUM(is_late)                                   AS total_late_orders,
        ROUND(AVG(CAST(is_late AS FLOAT)) * 100, 2)    AS late_rate_pct,
        ROUND(SUM(seller_gmv), 2)                      AS total_gmv
    FROM silver_order_seller
    GROUP BY seller_id
    HAVING COUNT(*) >= 20
)
SELECT
    seller_id,
    total_orders,
    total_late_orders,
    late_rate_pct,
    total_gmv,
    SUM(total_late_orders) OVER (ORDER BY total_late_orders DESC, seller_id
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)            AS running_total,
    ROUND(100.0 * SUM(total_late_orders) OVER (ORDER BY total_late_orders DESC, seller_id
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
         / SUM(total_late_orders) OVER (), 2)                         AS cumulative_pct,
    ROW_NUMBER() OVER (ORDER BY total_late_orders DESC, seller_id)    AS seller_rank,
    COUNT(*) OVER ()                                                  AS eligible_sellers,
    ROUND(100.0 * ROW_NUMBER() OVER (ORDER BY total_late_orders DESC, seller_id)
         / COUNT(*) OVER (), 2)                                       AS seller_percentage
FROM lateSeller
ORDER BY total_late_orders DESC, seller_id;

-- Q3b. Compare the group behind 80% of late orders with the other eligible sellers
;WITH s AS (
    SELECT seller_id, COUNT(*) AS orders, SUM(is_late) AS late
    FROM silver_order_seller
    GROUP BY seller_id
    HAVING COUNT(*) >= 20
),
r AS (
    SELECT seller_id, orders, late,
           SUM(late) OVER (ORDER BY late DESC, seller_id
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running,
           SUM(late) OVER () AS total_late
    FROM s
),
g AS (
    SELECT *,
           CASE WHEN running - late < 0.8 * total_late
                THEN '1. Top group (80% of late orders)'
                ELSE '2. Other eligible sellers' END AS grp
    FROM r
)
SELECT
    grp,
    COUNT(*)                                                      AS sellers,
    SUM(orders)                                                   AS orders,
    ROUND(100.0 * SUM(orders) / SUM(SUM(orders)) OVER (), 2)      AS order_share_pct,
    SUM(late)                                                     AS late_orders,
    ROUND(100.0 * SUM(late) / SUM(orders), 2)                     AS late_rate_pct
FROM g
GROUP BY grp
ORDER BY grp;

-- Q3c. Coverage: how many late rows come from eligible sellers vs all sellers
;WITH s AS (
    SELECT seller_id, COUNT(*) AS orders, SUM(is_late) AS late
    FROM silver_order_seller
    GROUP BY seller_id
)
SELECT
    SUM(CASE WHEN orders >= 20 THEN late ELSE 0 END)  AS late_in_eligible_sellers,
    SUM(late)                                         AS late_in_all_sellers,
    SUM(CASE WHEN orders >= 20 THEN 1 ELSE 0 END)     AS eligible_sellers,
    COUNT(*)                                          AS all_sellers
FROM s;

/*
Insight: 252 of 804 sellers with 20+ orders (31.3%) account for 80% of the late orders
         from that group (Q3b). Concentration is moderate, not a strict 80/20.
Evidence: The eligible sellers hold 5,752 of the 6,547 late order-seller rows (87.9%) (Q3c).
          The top group handles 68.07% of eligible orders (58,474) and has a late rate of 7.88%,
          against 4.18% for the other 552 eligible sellers (Q3b), about 1.9 times higher.
          The 20 sellers with the most late orders account for 1,611 late orders (about 28% of 5,752).
          The top 20% of eligible sellers (161 of 804) account for 68.9% of late orders (Q3a, row 161),
          so the classic 80/20 rule is close but not exact: roughly 69/20 and 80/31.
Recommendation (Seller Management): coach the sellers in the top group with the highest late rate first,
          with warnings for those that do not improve. Monitor the rest of the group.
Estimated impact (hypothetical): if the top group matched the 4.18% late rate of the others, its late
          orders would fall from 4,605 to about 2,444 (about 2,161 fewer, roughly 38% of eligible late orders).
Limits: order-seller grain, so totals differ slightly from order-level totals (6,547 vs 6,534 late).
        Carrier transit is the main delay stage (Q1), so a seller's late rate may partly reflect
        its region and carrier mix, not only its own handling.
        Seller counts: 804 eligible sellers of 2,970 in total. 92 eligible sellers have no late orders,
        so the Pareto chart shows 712 bars.
*/


/* =====================================================================
   Q4. WHAT IS THE GMV EXPOSURE?   (BRD core question 4, objective O4)
   GMV in late orders and in late, low-rated orders, plus hypothetical scenarios.
   This is exposure, not lost revenue.
   Stakeholder: Finance
   Decision: how much GMV is exposed to delivery problems
   ===================================================================== */

-- Q4a. GMV exposure
SELECT
    SUM(total_gmv)                                                              AS total_company_gmv,
    SUM(CASE WHEN is_late = 1 THEN total_gmv ELSE 0 END)                        AS late_gmv,
    SUM(CASE WHEN is_late = 1 AND review_score <= 2 THEN total_gmv ELSE 0 END)  AS late_low_rated_gmv,
    ROUND(100.0 * SUM(CASE WHEN is_late = 1 THEN total_gmv ELSE 0 END)
          / SUM(total_gmv), 2)                                                  AS late_gmv_share_pct
FROM silver_orders;

-- Q4b. Orders and GMV by late flag
SELECT
    is_late,
    COUNT(*)        AS total_orders,
    SUM(total_gmv)  AS sum_gmv
FROM silver_orders
GROUP BY is_late;

-- Q4c. Hypothetical scenarios: late rate falls by 1, 2, 3 and 5 points.
-- (10 points is not used: the late rate is below 10%, so it would remove every late order.)
-- Assumption: shifted orders carry the average GMV of late orders.
;WITH base AS (
    SELECT
        COUNT(*)                                                       AS delivered,
        SUM(is_late)                                                   AS late,
        SUM(CASE WHEN is_late = 1 THEN total_gmv END) * 1.0
            / NULLIF(SUM(is_late), 0)                                  AS avg_late_gmv
    FROM silver_orders
)
SELECT
    p.pts                                       AS late_rate_reduction_points,
    ROUND(x.shifted, 0)                         AS orders_shifted_to_on_time,
    ROUND(x.shifted * b.avg_late_gmv, 2)        AS gmv_associated_hypothetical
FROM base b
CROSS JOIN (VALUES (1), (2), (3), (5)) AS p(pts)
CROSS APPLY (
    SELECT CASE WHEN b.delivered * p.pts / 100.0 < b.late
                THEN b.delivered * p.pts / 100.0
                ELSE b.late END AS shifted
) x
ORDER BY p.pts;

-- Q4d. Cross-check with the BRD definition of order GMV (item price plus freight)
SELECT
    SUM(total_gmv + total_freight)                                                          AS total_gmv_incl_freight,
    SUM(CASE WHEN is_late = 1 THEN total_gmv + total_freight ELSE 0 END)                    AS late_gmv_incl_freight,
    SUM(CASE WHEN is_late = 1 AND review_score <= 2 THEN total_gmv + total_freight ELSE 0 END) AS late_low_rated_incl_freight,
    ROUND(100.0 * SUM(CASE WHEN is_late = 1 THEN total_gmv + total_freight ELSE 0 END)
          / SUM(total_gmv + total_freight), 2)                                              AS late_share_incl_freight_pct
FROM silver_orders;

/*
Insight: Late orders carry 7.46% of total GMV (Q4a), and most of that exposure sits in low-rated orders.
Evidence: Total GMV 13,220,249, late GMV 985,924, late and low-rated GMV 619,012
          (62.8% of late GMV, 4.7% of total GMV).
Recommendation (Finance and Head of Operations): treat about 1.0M of GMV in late orders as the exposure
          to protect, and prioritise fixes that cut late orders with low reviews first (carrier transit, Q1).
Estimated impact (hypothetical): a 1-point fall in the late rate shifts 965 orders and is
          associated with 145,565 GMV; a 3-point fall, 2,894 orders and 436,695 GMV (Q4c).
          A 5-point fall (4,824 orders, 727,825 GMV) would remove about 74% of all late orders,
          so treat it as an upper bound, not a realistic target.
Definition note: GMV here is item price only. The BRD says price plus freight; Q4d gives that version.
       Q4d result: total 15,418,394.83; late 1,150,892.13; late and low-rated 720,975.01; late share 7.46%
       (the same 7.46% as Q4a, so the conclusion does not depend on the definition).
Limit: GMV in late orders is exposure, not lost revenue. All scenarios are hypothetical.
       The BRD suggests 5 and 10 points, but the late rate is below 10%, so 10 points is not realistic.
*/


/* =====================================================================
   FR8. DATA EXTRACT FOR THE PYTHON LOGISTIC REGRESSION
   Low review vs other, using late flag, category, freight and order value.
   One row per order. Category = highest-priced item (documented rule in the view).
   ===================================================================== */
SELECT
    order_id,
    is_late,
    review_score,
    is_low_review,
    total_freight,
    total_gmv,
    category
FROM gold_fact_orders;


/* =====================================================================
   S1. HOW HAS THE LATE DELIVERY RATE CHANGED MONTH BY MONTH?
   (BRD supporting question 1, objective O1)  Month = purchase month.
   Stakeholder: Head of Operations
   ===================================================================== */
SELECT
    FORMAT(order_purchase_timestamp, 'yyyy-MM')       AS order_month,
    COUNT(*)                                          AS total_orders,
    ROUND(AVG(CAST(is_late AS FLOAT)) * 100, 2)       AS late_rate_pct
FROM silver_orders
GROUP BY FORMAT(order_purchase_timestamp, 'yyyy-MM')
ORDER BY order_month;

/*
Insight: The late rate is volatile and rises when order volume surges.
Evidence: From Jan to Aug 2017 the rate stayed between 2.79% and 6.56% (Apr 2017 was the high at 6.56%).
          In Nov 2017 orders rose from 4,478 (Oct) to 7,288 and the late rate rose from 4.18% to 12.40%.
          Peak month: Mar 2018 at 18.96%, about 2.8 times the overall rate of 6.77%.
Recommendation (Head of Operations): plan carrier capacity ahead of peak months and review what
          happened operationally in the worst months.
Limit: volume and lateness move together here, but this data cannot show the reason.
*/


/* =====================================================================
   S2. WHICH STATES AND PRODUCT CATEGORIES PERFORM WORST?
   (BRD supporting question 2)
   Stakeholder: Logistics Manager (states), Head of Operations (categories)
   ===================================================================== */

-- S2a. States (minimum 500 orders). Re-sort by low_review_pct to see the review view.
SELECT
    customer_state,
    COUNT(*)                                                       AS total_orders,
    ROUND(AVG(CAST(is_late AS FLOAT)) * 100, 2)                    AS late_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
          / COUNT(review_score), 2)                                AS low_review_pct
FROM silver_orders
GROUP BY customer_state
HAVING COUNT(*) > 500
ORDER BY late_rate_pct DESC;

-- S2b. Categories (minimum 500 orders), order level, English names
SELECT
    category,
    COUNT(*)                                                       AS total_orders,
    ROUND(AVG(CAST(is_late AS FLOAT)) * 100, 2)                    AS late_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
          / COUNT(review_score), 2)                                AS low_review_pct
FROM gold_fact_orders
GROUP BY category
HAVING COUNT(*) > 500
ORDER BY late_rate_pct DESC;

/*
Insight: The worst states by late rate are MA (17.43%, 717 orders), CE (13.76%, 1,279), BA (12.16%, 3,256),
         RJ (12.11%, 12,350) and PA (11.21%, 946), against 6.77% overall.
         RJ is also large: about 1,500 late orders from 12,350 orders.
         Sao Paulo has the most orders and a low late rate: 40,494 orders, late rate 4.49%, low-review rate 10.7%.
Recommendation (Logistics Manager): focus regional carrier reviews on those states, not on the whole country.
Categories: differences are small. The top five are BABY (8.12%), OFFICE_FURNITURE (8.07%),
         ELECTRONICS (7.67%), MUSICAL_INSTRUMENTS (7.58%) and HEALTH_BEAUTY (7.54%), against 6.77% overall.
         OFFICE_FURNITURE also has the highest low-review rate of these (21.9%).
         Region varies far more than category, so regional carriers matter more than product type.
Note: the category rule is the highest-priced item of the order, so an order with several categories
         is counted once.
*/


/* =====================================================================
   S3. HOW SEVERE ARE THE WORST 10% OF DELAYS?
   (BRD supporting question 3)  Late orders only (is_late = 1).
   Stakeholder: Head of Operations
   ===================================================================== */
SELECT DISTINCT
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY deliv_delay_days) OVER () AS DECIMAL(10,2)) AS median_delay_days,
    CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY deliv_delay_days) OVER () AS DECIMAL(10,2)) AS p90_delay_days
FROM silver_orders
WHERE is_late = 1;

/*
Insight: The company usually delivers on time or early, but a long tail of severe delays exists.
Evidence: Among late orders the median delay is 7 days and the 90th percentile is 22 days,
          so half of all late orders are more than 7 days late and the worst 10% are more than 22 days late.
          (Same values as the Median and P90 cards on page 2 of the dashboard.)
          Possible reasons (not tested in this data): lost packages, misrouted shipments, regional disruption.
Recommendation (Head of Operations): two tiers.
          Tier 1: reduce typical delays of about a week (the median late order is 7 days late) through
          carrier speed and regional carrier reviews.
          Tier 2: an escalation rule, for example investigate or refund proactively when a package
          is 10 days past its estimated date, well before it reaches the 22-day P90 mark.
Estimated impact: in the 16+ days band 78.31% of reviews are low (1,225 orders, Q2).
          This is an association, not a proven effect of the delay.
*/