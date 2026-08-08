with source as (
    select * from {{ source('raw', 'raw_amazon_products') }}
),

deduped as (
    -- 114 product_ids appear twice in the raw file, keep the one with more populated review data
    select *
    from source
    qualify row_number() over (partition by product_id order by rating_count desc) = 1
),

cleaned as (
    select
        product_id,
        product_name,

        category as category_raw,
        split_part(category, '|', 1) as category_level_1,
        split_part(category, '|', 2) as category_level_2,   
        split_part(category, '|', -1) as category_last_level,

        try_cast(replace(replace(discounted_price, '₹', ''), ',', '') as number(10,2)) as discounted_price,
        try_cast(replace(replace(actual_price, '₹', ''), ',', '') as number(10,2)) as actual_price,
        try_cast(replace(discounted_percentage, '%', '') as number(5,2)) as discounted_percentage,

        -- try_cast turns the one malformed "|" rating into NULL instead of erroring
        try_cast(rating as float) as rating,
        try_cast(replace(rating_count, ',', '') as integer) as rating_count,

        about_product
    from deduped
)

select * from cleaned