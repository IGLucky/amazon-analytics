# Amazon Product Analytics: Bronze to Gold on Snowflake + dbt

An end-to-end analytics engineering pipeline built on a single Amazon product dataset. Raw CSV lands in Snowflake, is transformed through Bronze, Silver and Gold layers in dbt Core, tested at every stage, and surfaced in a Tableau dashboard.

---

## Stack

| Layer | Tool |
|---|---|
| Warehouse | Snowflake |
| Transformation | dbt Core |
| Version control | Git / GitHub (feature branches, pull requests) |
| Visualisation | Tableau Desktop (native Snowflake connector) |
| IDE | VS Code |

---

## Architecture

```
amazon.csv
    |
    v
RAW.RAW_AMAZON_PRODUCTS          Bronze: loaded as-is, all VARCHAR, nothing altered
    |
    v
SILVER.CLEAN_AMAZON_PRODUCTS     Silver: deduplicated, typed, category split
SILVER.STG_AMAZON_REVIEWS        Silver: review arrays exploded to one row per review
    |
    v
GOLD.DIM_PRODUCTS                Gold: product dimension with derived business tiers
GOLD.FCT_PRODUCT_REVIEWS         Gold: review fact table with product context
GOLD.AGG_CATEGORY_PERFORMANCE    Gold: category-grain KPI rollup
    |
    v
Tableau dashboard
```

Silver models are materialised as **views** (cheap intermediate steps, rebuilt constantly during development). Gold models are materialised as **tables**, because a dashboard fires repeated queries against them and should not re-run the full transformation chain on every refresh.

---

## The core problem: a hidden one-to-many relationship

The source looks like a flat table of 1,465 products. It is not.

Five columns (`user_id`, `user_name`, `review_id`, `review_title`, `review_content`) each contain **multiple values comma-packed into a single cell**. A single row typically represents one product *and* eight reviews.

```
user_id:  AG3D6O4STAQKAY2UVGEUV46KN35Q, AHMY5CWJMMK5BJRBBSNLYT3ONILA, ...
```

`stg_amazon_reviews` unpacks this into **11,220 individual review rows** using `SPLIT`, `ARRAY_GENERATE_RANGE` and `LATERAL FLATTEN`, each carrying `product_id` as a foreign key back to the product dimension.

### Why this is harder than it looks

Splitting on a comma is safe for structured IDs. It is **not** safe for free text, because customers write commas in their own sentences:

```
Raw:    Works great,Charging is really fast, good product.,Cheap but fine
Split:  ["Works great"] ["Charging is really fast"] [" good product."] ["Cheap but fine"]
        3 real reviews -> 4 fragments
```

Once the source joined those reviews with a comma, the distinction between a separating comma and a comma inside a sentence was permanently destroyed. No amount of SQL recovers it.

A naive implementation zips all five columns by position and produces output that *looks* perfect: every row populated, no errors, plausible counts. But reviewer names silently attach to the wrong review text. That is the worst class of data bug, one that produces confident wrong answers rather than visible failures.

### The decision

Row count is sized from the **structured ID columns only**, which do not contain commas. `review_content` is validated separately:

- `is_malformed_review_array` fires when the ID columns disagree in length (**450 products**)
- `review_content_may_be_misaligned` fires when the text splits into a different count (**1,151 products, 85%**)

Where alignment cannot be trusted, per-review text is set to `NULL` rather than guessed. The complete unsplit blob is preserved as `review_content_raw`, so nothing is destroyed, it is only marked untrustworthy for row-level joining. Product-level text analysis remains possible.

**Flag and preserve, rather than flag and discard.**

### How the bug was caught

The first version of this model returned 20,333 review rows. Nothing failed. dbt reported success and every test passed. But 20,333 across 1,351 products is roughly 15 reviews each, which did not match the source.

Investigating that number revealed the cause: row count was being sized from the *longest* array, and `review_content` was systematically longest because it was over-splitting. Separating "how many reviews are there" from "can the text be trusted" corrected it to **11,220**, or about 8.3 per product, which matches the source.

The corrected structural mismatch count (450) also lands close to an independent count of 476 obtained by profiling the raw CSV in Python before any modelling began.

---

## Other data quality work

**Deduplication.** 114 `product_id` values appear twice. Resolved with `QUALIFY ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY rating_count DESC) = 1`, reducing 1,465 rows to **1,351 unique products**.

**Type casting.** Prices arrive as `"₹1,099"`, discounts as `"64%"`, rating counts as `"24,269"`. Symbols and separators are stripped, then cast with `TRY_CAST` rather than `CAST`. This matters: one product (`B08L12N5H1`) has a rating of `"|"` instead of a number. A strict `CAST` would fail the entire model on all 1,351 rows because of one bad value. `TRY_CAST` returns `NULL` for that row and continues.

**Category hierarchy.** `category` is pipe-delimited and between 2 and 7 levels deep. Split into `category_level_1`, `category_level_2` and `category_last_level`, with the original preserved as `category_raw`.

**Discount cross-validation.** The source states a `discount_percentage`, and both prices are available, so the value can be derived independently. Across all 1,351 products, **zero disagree by more than 0.50 percentage points**. That ceiling is the mathematical signature of rounding a whole number, which means the field is calculated from the two prices rather than independently sourced. It therefore carries no information the price columns do not already contain, and could never reveal a pricing error.

**Ingestion.** The Snowsight load wizard produced generic column names, then loaded the header row as data. Replaced with explicit SQL: a named `FILE FORMAT` (`SKIP_HEADER = 1`, `FIELD_OPTIONALLY_ENCLOSED_BY = '"'`), a `STAGE`, and `COPY INTO`. For anything that must be reproducible, explicit beats convenient.

---

## Testing

18 dbt tests, all passing.

| Test | Covers |
|---|---|
| `unique`, `not_null` | Primary keys on `clean_amazon_products`, `dim_products`, `agg_category_performance` |
| `not_null` | Price fields, category, review index |
| `relationships` | `stg_amazon_reviews` -> `clean_amazon_products`, `fct_product_reviews` -> `dim_products` |
| `accepted_values` | `price_tier` and `discount_band` band definitions |
| Singular test | `rating` falls within 0 to 5 |

The `accepted_values` tests catch a specific failure the others cannot: if a threshold in a `CASE` statement is later edited and introduces a gap, a product could fall into an unexpected bucket. This fails immediately rather than surfacing as a mystery category in a dashboard filter weeks later.

Grain is verified by row count after every join. `dim_products` must return 1,351 and `fct_product_reviews` must return 11,220. A malformed join inflates row counts silently and quietly corrupts every average downstream.

---

## The semantic layer

Gold is where business definitions live, in code, in version control:

- **`price_tier`**: Budget / Mid-range / Premium / High-end
- **`discount_band`**: None / Light / Moderate / Heavy
- **`rating_band`**: Poor / Average / Good / Excellent

Nothing in the data says 500 rupees is the boundary between Budget and Mid-range. That is a decision. Defining it in dbt rather than in Tableau means every dashboard and every analyst uses the same definition, and changing it changes it everywhere at once.

This is also the practical rule for where new logic belongs: **fixing something broken goes in Silver, deciding something goes in Gold.** No Gold model contains a `TRY_CAST` or a `REPLACE`.

---

## Findings

**Price and customer satisfaction are decoupled.** Average price varies by a factor of twenty across categories (302 to 6,225 rupees) while average rating varies by a quarter of a star (4.04 to 4.31).

**Cheaper categories produce top-rated products more often.** Share of products rated 4.5 or above:

| Category | Products | % rated 4.5+ | Avg price |
|---|---|---|---|
| OfficeProducts | 31 | 22.6% | 302 |
| Computers & Accessories | 375 | 9.9% | 947 |
| Home & Kitchen | 448 | 6.5% | 2,331 |
| Electronics | 490 | 4.5% | 6,225 |

Average rating compresses everything into a narrow band and hides this. `pct_excellent` separates the categories by a factor of five. A plausible explanation is expectation scaling: a 300 rupee item either works or it does not, while a 6,000 rupee item offers far more ways to disappoint. That mechanism cannot be proven from this data.

**Deeper discounts track with lower ratings, monotonically.** 4.24 (no discount) to 4.15 to 4.09 to 4.04 (60%+). But review volume does not increase with discount depth: it jumps from undiscounted to discounted, then flattens. Deep discounting is not buying engagement.

**Direction of causation is unknown.** Sellers plausibly discount products heavily *because* they already rate poorly, rather than discounting causing dissatisfaction. This is correlation and is labelled as such on the dashboard.

---

## Known limitations

- **The dedup tiebreak is under-justified.** Duplicate rows are resolved by highest `rating_count`, but whether any duplicate pair actually differs was never verified. If they are exact copies, any tiebreak works and that should be stated.
- **Bronze is not reproducible from the repo.** The CSV was uploaded manually to a stage. Anyone cloning this cannot rebuild the raw layer without those steps.
- **No Python.** All transformation is SQL. Data profiling that informed the design was done in Python but is not committed.
- **No CI.** Git with feature branches and pull requests is in place, but no GitHub Action runs `dbt build` on push.
- **Small categories are noise.** Four of nine categories contain one or two products. They are filtered out of the dashboard rather than presented as trends.
- **Tableau dashboard is not publicly hosted.** Tableau Public does not support live Snowflake connections. The workbook is committed as a packaged `.twbx`.

---

## Repo structure

```
models/
  silver/
    _sources.yml                    source declaration for the raw table
    clean_amazon_products.sql       dedup, type casting, category split
    stg_amazon_reviews.sql          review array explosion with quality flags
    schema.yml                      tests and documentation
  gold/
    dim_products.sql                product dimension with business tiers
    fct_product_reviews.sql         review fact with product context
    agg_category_performance.sql    category-grain KPI rollup
    schema.yml                      tests and documentation
macros/
  generate_schema_name.sql          overrides dbt's default schema concatenation
tests/
  assert_rating_in_range.sql        singular test, rating between 0 and 5
tableau/
  amazon_satisfaction_dashboard.twbx
```

---

## Running it

```bash
pip install dbt-snowflake
dbt debug        # verify the Snowflake connection
dbt run          # build all Silver and Gold models
dbt test         # run all 18 tests
dbt docs generate && dbt docs serve   # browsable lineage graph
```

Requires a Snowflake account with `AMAZON_ANALYTICS.RAW.RAW_AMAZON_PRODUCTS` loaded. Setup SQL for the file format, stage and raw table is in `setup/`.
