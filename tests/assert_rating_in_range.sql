select *
from {{ ref('clean_amazon_products') }}
where rating is not null
  and (rating < 0 or rating > 5)