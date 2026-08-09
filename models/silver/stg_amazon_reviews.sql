with source as (
    select * from {{ source('raw', 'raw_amazon_products') }}
),

deduped as (
    -- same dedup logic as stg_amazon_products, so we don't explode reviews twice for the 114 duplicate product rows
    select *
    from source
    qualify row_number() over (
        partition by product_id
        order by try_cast(replace(rating_count, ',', '') as integer) desc
    ) = 1
),

split_arrays as (
    select
        product_id,
        review_content as review_content_raw,
        split(user_id, ',') as user_id_arr,
        split(user_name, ',') as user_name_arr,
        split(review_id, ',') as review_id_arr,
        split(review_title, ',') as review_title_arr,
        split(review_content, ',') as review_content_arr
    from deduped
),

with_flags as (
    select
        *,
        -- "identity" columns: structured values, essentially never contain a literal comma
        greatest(
            array_size(user_id_arr),
            array_size(user_name_arr),
            array_size(review_id_arr),
            array_size(review_title_arr)
        ) as review_count,
        not (
            array_size(user_id_arr) = array_size(user_name_arr)
            and array_size(user_id_arr) = array_size(review_id_arr)
            and array_size(user_id_arr) = array_size(review_title_arr)
        ) as is_malformed_review_array,
        -- review_content is free text and can legitimately contain commas, tracked separately
        array_size(review_content_arr) != greatest(
            array_size(user_id_arr),
            array_size(user_name_arr),
            array_size(review_id_arr),
            array_size(review_title_arr)
        ) as review_content_may_be_misaligned
    from split_arrays
),

exploded as (
    select
        w.product_id,
        w.review_content_raw,
        w.is_malformed_review_array,
        w.review_content_may_be_misaligned,
        idx.value::int as review_index,
        trim(w.user_id_arr[idx.value::int]::string) as user_id,
        trim(w.user_name_arr[idx.value::int]::string) as user_name,
        trim(w.review_id_arr[idx.value::int]::string) as review_id,
        trim(w.review_title_arr[idx.value::int]::string) as review_title,
        case
            when w.review_content_may_be_misaligned then null
            else trim(w.review_content_arr[idx.value::int]::string)
        end as review_content
    from with_flags w,
    lateral flatten(input => array_generate_range(0, w.review_count)) idx
)

select * from exploded
order by product_id, review_index