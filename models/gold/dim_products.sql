with products as (
    select * from {{ ref('clean_amazon_products') }}
),

review_counts as (
    select
        product_id,
        count(*) as sampled_review_count,
        max(is_malformed_review_array) as has_malformed_review_arrays
    from {{ ref('stg_amazon_reviews') }}
    group by product_id
),

final as (
    select
        p.product_id,
        p.product_name,

        p.category_level_1 as category,
        p.category_level_2 as subcategory,
        p.category_last_level as category_leaf,

        p.actual_price,
        p.discounted_price,
        p.actual_price - p.discounted_price as discount_amount,
        p.discounted_percentage,

        round(
            (p.actual_price - p.discounted_price) / nullif(p.actual_price, 0) * 100, 2
        ) as derived_discount_percentage,

        abs(
            round((p.actual_price - p.discounted_price) / nullif(p.actual_price, 0) * 100, 2)
            - p.discounted_percentage
        ) > 1 as discount_percentage_mismatch,

        p.rating,
        p.rating_count as reported_rating_count,
        coalesce(r.sampled_review_count, 0) as sampled_review_count,
        coalesce(r.has_malformed_review_arrays, false) as has_malformed_review_arrays,

        case
            when p.discounted_price < 500 then 'Budget'
            when p.discounted_price < 2000 then 'Mid-range'
            when p.discounted_price < 10000 then 'Premium'
            else 'High-end'
        end as price_tier,

        case
            when p.discounted_percentage >= 60 then 'Heavy (60%+)'
            when p.discounted_percentage >= 30 then 'Moderate (30-59%)'
            when p.discounted_percentage > 0 then 'Light (1-29%)'
            else 'None'
        end as discount_band,

        case
            when p.rating >= 4.5 then 'Excellent'
            when p.rating >= 4.0 then 'Good'
            when p.rating >= 3.0 then 'Average'
            when p.rating is not null then 'Poor'
        end as rating_band

    from products p
    left join review_counts r on p.product_id = r.product_id
)

select * from final