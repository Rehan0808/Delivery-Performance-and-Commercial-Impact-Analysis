SELECT 'Orders Duplicates' AS CheckName, COUNT(*) AS DuplicateCount
FROM (
    SELECT order_id FROM bronze_olist_orders GROUP BY order_id HAVING COUNT(*) > 1
) t

UNION ALL

-- 2. Customers: Is customer_id unique? (Remember, customer_id is per-order!)
SELECT 'Customers Duplicates', COUNT(*)
FROM (
    SELECT customer_id FROM bronze_olist_customers GROUP BY customer_id HAVING COUNT(*) > 1
) t

UNION ALL

-- 3. Sellers: Is seller_id unique?
SELECT 'Sellers Duplicates', COUNT(*)
FROM (
    SELECT seller_id FROM bronze_olist_sellers GROUP BY seller_id HAVING COUNT(*) > 1
) t

UNION ALL

-- 4. Products: Is product_id unique?
SELECT 'Products Duplicates', COUNT(*)
FROM (
    SELECT product_id FROM bronze_olist_products GROUP BY product_id HAVING COUNT(*) > 1
) t

UNION ALL

-- 5. Reviews: Are there orders with MULTIPLE reviews?
SELECT 'Review Duplicates', COUNT(*)
FROM (
    SELECT order_id FROM bronze_olist_order_reviews GROUP BY order_id HAVING COUNT(*) > 1
) t

UNION ALL

-- 6. Order Items: What is the grain? 
SELECT 'Order Items Duplicates', COUNT(*)
FROM (
    SELECT order_id, order_item_id FROM bronze_olist_order_items GROUP BY order_id, order_item_id HAVING COUNT(*) > 1
) t;



-- 547 review duplicates are found 

select  * 
from bronze_olist_order_reviews
where order_id in(
 SELECT order_id 
    FROM bronze_olist_order_reviews 
    GROUP BY order_id 
    HAVING COUNT(*) > 1
)
order by order_id 

-- Categorical Distribution (Validity)

SELECT order_status, COUNT(*) FROM bronze_olist_orders GROUP BY order_status


SELECT 
    SUM(CASE WHEN order_approved_at IS NULL THEN 1 ELSE 0 END) AS Missing_Approved_Date,
    SUM(CASE WHEN order_delivered_carrier_date IS NULL THEN 1 ELSE 0 END) AS Missing_Carrier_Date,
    SUM(CASE WHEN order_delivered_customer_date IS NULL THEN 1 ELSE 0 END) AS Missing_Customer_Date
FROM bronze_olist_orders
WHERE order_status = 'delivered';

SELECT 
MIN(price) AS Min_Price,
MAX(price) AS Max_Price, 
AVG(price) AS Avg_Price,
MIN(freight_value) AS Min_Freight, 
MAX(freight_value) AS Max_Freight 
FROM 
bronze_olist_order_items

-- CHECKING DATES
SELECT 
MIN(order_purchase_timestamp) as firstorder,
MAX(order_purchase_timestamp) as lastorder
FROM 
bronze_olist_orders;


SELECT
COUNT(*) AS Orphan_Orders
FROM bronze_olist_orders AS o
LEFT JOIN bronze_olist_customers c ON o.customer_id = c.customer_id 
WHERE c.customer_id IS NULL;


select 
count(*) 
from 
bronze_olist_orders 

select 
count(*) 
from 
bronze_olist_order_items

select 
count(*) as Row_after_joins
from 
bronze_olist_orders o
join bronze_olist_order_items i on o.order_id = i.order_id