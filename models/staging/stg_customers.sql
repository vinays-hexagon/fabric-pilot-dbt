with source as (
    select * from {{ ref('raw_customers') }}
),

renamed as (
    select
        customer_id,
        customer_name_legal,
        account_type,
        organization_code,
        sales_region,
        country_code,
        cast(created_date as date) as created_date
    from source
)

select * from renamed
