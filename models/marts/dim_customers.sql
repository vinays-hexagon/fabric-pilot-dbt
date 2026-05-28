with customers as (
    select * from {{ ref('stg_customers') }}
),

organizations as (
    select * from {{ ref('stg_organizations') }}
),

final as (
    select
        c.customer_id,
        c.customer_name_legal,
        c.account_type,
        c.sales_region,
        c.country_code,
        c.created_date,
        o.organization_code,
        o.business_area,
        o.division,
        o.business_lifecycle,
        o.is_product_lifecycle
    from customers c
    left join organizations o
        on c.organization_code = o.organization_code
)

select * from final
