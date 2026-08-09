with reviews as (
    select * from {{ ref('stg_amazon_reviews') }}
),

products as (
    select
        product_id,
        product_name,
        category,
        subcategory,
        price_tier,
        discount_band,
        rating_band,
        rating as product_rating,
        discounted_price
    from {{ ref('dim_products') }}
)

select
    r.review_id,
    r.product_id,
    r.review_index,

    p.product_name,
    p.category,
    p.subcategory,
    p.price_tier,
    p.discount_band,
    p.rating_band,
    p.product_rating,
    p.discounted_price,

    r.user_id,
    r.user_name,
    r.review_title,
    r.review_content,
    r.review_content_raw,

    r.is_malformed_review_array,
    r.review_content_may_be_misaligned,

    length(r.review_content) as review_content_length

from reviews r
inner join products p on r.product_id = p.product_id