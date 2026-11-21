SELECT 'Customers' AS TableName, COUNT(*) AS RowCounts FROM bronze_olist_customers
UNION ALL
SELECT 'Geolocation', COUNT(*) FROM bronze_olist_geolocation
UNION ALL
SELECT 'Orders', COUNT(*) FROM bronze_olist_orders
UNION ALL
SELECT 'Order Items', COUNT(*) FROM bronze_olist_order_items
UNION ALL
SELECT 'Payments', COUNT(*) FROM bronze_olist_order_payments
UNION ALL
SELECT 'Reviews', COUNT(*) FROM bronze_olist_order_reviews
UNION ALL
SELECT 'Products', COUNT(*) FROM bronze_olist_products
UNION ALL
SELECT 'Sellers', COUNT(*) FROM bronze_olist_sellers
UNION ALL
SELECT 'Category Translation', COUNT(*) FROM bronze_product_category_name_translation;