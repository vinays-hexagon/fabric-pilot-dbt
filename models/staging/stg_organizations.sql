with source as (
    select * from {{ ref('raw_organizations') }}
),

renamed as (
    select
        organization_code,
        business_area,
        division,
        business_lifecycle,
        region,
        case
            when business_lifecycle = 'Product' then cast(1 as bit)
            else cast(0 as bit)
        end as is_product_lifecycle
    from source
)

select * from renamed
