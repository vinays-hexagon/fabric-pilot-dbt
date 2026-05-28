with orders as (
    select * from {{ ref('stg_orders') }}
),

customers as (
    select * from {{ ref('dim_customers') }}
),

final as (
    select
        o.order_id,
        o.order_date,
        o.product_id,
        o.quantity,
        o.unit_price,
        o.order_total,
        o.currency,
        o.status,
        c.customer_id,
        c.customer_name_legal,
        c.account_type,
        c.sales_region,
        c.business_area,
        c.division,
        datepart(year, o.order_date)    as order_year,
        datepart(quarter, o.order_date) as order_quarter,
        datepart(month, o.order_date)   as order_month
    from orders o
    left join customers c
        on o.customer_id = c.customer_id
)

select * from final
