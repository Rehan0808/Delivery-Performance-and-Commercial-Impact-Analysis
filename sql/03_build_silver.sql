/* =====================================================================
   03_build_silver.sql
   Olist Delivery Performance & Commercial Impact Analysis
   Builds the cleaned silver layer from the bronze tables.

   Creates:
     silver_orders        one row per delivered order
     silver_order_seller  one row per order and seller

   Cleaning rules (all logged in docs/data_quality_log.md):
   1. Delivered orders only, with a customer delivery date.
   2. Items are aggregated to order level BEFORE joining (prevents join inflation).
   3. Duplicate reviews: one review per order. Prefer a review with a comment,
      then the most recent review_creation_date.
   4. Late flag is DATE based: delivered date later than estimated date.
      The estimated date is stored at midnight, so a timestamp comparison wrongly
      flags orders delivered on the due day as late (1,292 orders, 8.1% vs 6.77%).
   5. GMV = item price only (freight is kept in its own column).

   Expected checks at the end of this file:
     96,470 delivered orders, 6,534 late, 0 mismatches, 6,547 late order-seller rows,
     total GMV 13,220,248.93.
   ===================================================================== */

DROP TABLE IF EXISTS silver_order_seller;
DROP TABLE IF EXISTS silver_orders;
GO

/* ---------- silver_orders: one row per delivered order ---------- */
WITH cleanReviews AS (
    SELECT
        order_id,
        review_score,
        review_comment_message,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY CASE WHEN review_comment_message IS NOT NULL THEN 0 ELSE 1 END,
                     review_creation_date DESC
        ) AS rn
    FROM bronze_olist_order_reviews
),
AggItems AS (
    SELECT
        order_id,
        COUNT(*)           AS total_items,
        SUM(price)         AS total_gmv,
        SUM(freight_value) AS total_freight
    FROM bronze_olist_order_items
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_id,
    c.customer_state,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,

    -- Stage times and delay (whole days; DATEDIFF counts midnight boundaries)
    DATEDIFF(DAY, o.order_purchase_timestamp,       o.order_approved_at)             AS approval_days,
    DATEDIFF(DAY, o.order_approved_at,              o.order_delivered_carrier_date)  AS seller_processing_days,
    DATEDIFF(DAY, o.order_delivered_carrier_date,   o.order_delivered_customer_date) AS carrier_transit_days,
    DATEDIFF(DAY, o.order_purchase_timestamp,       o.order_delivered_customer_date) AS total_delivery_days,
    DATEDIFF(DAY, o.order_purchase_timestamp,       o.order_estimated_delivery_date) AS promise_days,
    DATEDIFF(DAY, o.order_estimated_delivery_date,  o.order_delivered_customer_date) AS deliv_delay_days,

    -- Late flag: date based (see rule 4)
    CASE WHEN CAST(o.order_delivered_customer_date AS DATE)
              > CAST(o.order_estimated_delivery_date AS DATE)
         THEN 1 ELSE 0 END                                                           AS is_late,

    ISNULL(ag.total_items, 0)   AS total_items,
    ISNULL(ag.total_gmv, 0)     AS total_gmv,
    ISNULL(ag.total_freight, 0) AS total_freight,
    cr.review_score
INTO silver_orders
FROM bronze_olist_orders o
LEFT JOIN bronze_olist_customers c ON o.customer_id = c.customer_id
LEFT JOIN AggItems ag              ON o.order_id    = ag.order_id
LEFT JOIN cleanReviews cr          ON o.order_id    = cr.order_id AND cr.rn = 1
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;
GO

/* ---------- silver_order_seller: one row per order and seller ----------
   An order with two sellers appears twice (once per seller).
   is_late is copied from silver_orders so both tables always agree. */
SELECT
    oi.order_id,
    oi.seller_id,
    so.order_delivered_customer_date,
    so.order_estimated_delivery_date,
    so.is_late,
    COUNT(oi.order_item_id) AS seller_items,
    SUM(oi.price)           AS seller_gmv,
    SUM(oi.freight_value)   AS seller_freight
INTO silver_order_seller
FROM bronze_olist_order_items oi
JOIN silver_orders so ON oi.order_id = so.order_id
GROUP BY
    oi.order_id,
    oi.seller_id,
    so.order_delivered_customer_date,
    so.order_estimated_delivery_date,
    so.is_late;
GO

/* =====================================================================
   VALIDATION (keep these results in the quality log)
   ===================================================================== */

-- V1. Row counts and late orders. Expect 96,470 and 6,534.
SELECT COUNT(*) AS delivered_orders, SUM(is_late) AS late_orders FROM silver_orders;

-- V2. No duplicate orders. Expect 0.
SELECT COUNT(*) AS duplicate_orders
FROM (SELECT order_id FROM silver_orders GROUP BY order_id HAVING COUNT(*) > 1) t;

-- V3. No duplicate order-seller rows. Expect 0.
SELECT COUNT(*) AS duplicate_order_seller_rows
FROM (SELECT order_id, seller_id FROM silver_order_seller
      GROUP BY order_id, seller_id HAVING COUNT(*) > 1) t;

-- V4. Late flag agrees with delay days. Expect 0.
SELECT COUNT(*) AS mismatches
FROM silver_orders
WHERE (deliv_delay_days > 0 AND is_late = 0)
   OR (deliv_delay_days <= 0 AND is_late = 1);

-- V5. Late order-seller rows. Expect 6,547.
SELECT SUM(is_late) AS late_seller_rows FROM silver_order_seller;

-- V6. GMV reconciles to the source items of delivered orders. Expect 13,220,248.93 and difference 0.
SELECT
    (SELECT SUM(total_gmv) FROM silver_orders) AS silver_gmv,
    (SELECT SUM(oi.price)
       FROM bronze_olist_order_items oi
       JOIN silver_orders so ON so.order_id = oi.order_id) AS source_gmv;

-- V7. Seller table GMV equals order table GMV. Expect equal values.
SELECT
    (SELECT SUM(seller_gmv) FROM silver_order_seller) AS seller_table_gmv,
    (SELECT SUM(total_gmv)  FROM silver_orders WHERE total_items > 0) AS order_table_gmv;

-- V8. Delivered orders with no items (excluded from seller results). Log the number.
SELECT COUNT(*) AS delivered_orders_without_items FROM silver_orders WHERE total_items = 0;

-- V9. Stage times that are negative (timestamps out of order). Log the numbers and the decision.
SELECT
    SUM(CASE WHEN approval_days < 0           THEN 1 ELSE 0 END) AS negative_approval,
    SUM(CASE WHEN seller_processing_days < 0  THEN 1 ELSE 0 END) AS negative_seller_processing,
    SUM(CASE WHEN carrier_transit_days < 0    THEN 1 ELSE 0 END) AS negative_carrier_transit
FROM silver_orders;