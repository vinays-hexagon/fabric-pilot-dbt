with source as (
    select * from {{ ref('raw_orders') }}
),

renamed as (
    select
        order_id,
        customer_id,
        product_id,
        cast(order_date as date)          as order_date,
        cast(quantity as int)             as quantity,
        cast(unit_price as decimal(18,2)) as unit_price,
        currency,
        status,
        cast(quantity as decimal(18,2))
            * cast(unit_price as decimal(18,2)) as order_total
    from source
)

select * from renamed
