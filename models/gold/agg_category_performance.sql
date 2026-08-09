with products as (
    select * from {{ ref('dim_products') }}
),

reviews as (
    select
        category,
        count(*) as total_reviews,
        round(avg(review_content_length), 0) as avg_review_length
    from {{ ref('fct_product_reviews') }}
    where review_content is not null
    group by category
),

category_stats as (
    select
        p.category,

        count(*) as product_count,
        count(p.rating) as products_with_rating,

        round(avg(p.rating), 2) as avg_rating,
        round(median(p.rating), 2) as median_rating,
        min(p.rating) as min_rating,
        max(p.rating) as max_rating,

        round(avg(p.discounted_price), 2) as avg_price,
        round(median(p.discounted_price), 2) as median_price,
        round(avg(p.discounted_percentage), 1) as avg_discount_percentage,

        sum(p.reported_rating_count) as total_reported_ratings,
        round(avg(p.reported_rating_count), 0) as avg_reported_ratings_per_product,

        count(case when p.rating_band = 'Excellent' then 1 end) as excellent_products,
        count(case when p.discount_band = 'Heavy (60%+)' then 1 end) as heavily_discounted_products

    from products p
    group by p.category
)

select
    c.*,
    round(c.excellent_products / nullif(c.products_with_rating, 0) * 100, 1) as pct_excellent,
    round(c.heavily_discounted_products / nullif(c.product_count, 0) * 100, 1) as pct_heavily_discounted,
    coalesce(r.total_reviews, 0) as sampled_review_count,
    r.avg_review_length
from category_stats c
left join reviews r on c.category = r.category
order by c.product_count desc