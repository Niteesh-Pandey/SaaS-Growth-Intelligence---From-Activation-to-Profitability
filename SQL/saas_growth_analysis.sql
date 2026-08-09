/* ============================================================================
   SAAS ANALYTICS PROJECT — FULL STEP-BY-STEP FLOW
   Database : saas_analytics (PostgreSQL)
   Source   : saas_analytics_postgres.sql (uploaded dump)

   Flow:
     STEP 0 — Load
     STEP 1 — Explore (schema, row counts, ranges)
     STEP 2 — Data Quality Audit
     STEP 3 — Cleaning (views create, so every query use )
     STEP 4 — DAU / WAU / MAU
     STEP 5 — Funnel Analysis
     STEP 6 — Cohort Retention
     STEP 7 — CAC / CLV
   ============================================================================ */


/* ============================================================================
   STEP 0 — LOAD
   ============================================================================
   Terminal use:
     createdb saas_analytics
     psql -d saas_analytics -f saas_analytics_postgres.sql

  so five table import : users, subscriptions, events, marketing_spend,
   ab_test_assignments. 
   ============================================================================ */


/* ============================================================================
   STEP 1 — EXPLORE: fistly look data what combine inside
   ============================================================================ */

-- 1.1 Schema and row counts
SELECT 'users' AS table_name, COUNT(*) AS rows FROM users
UNION ALL SELECT 'subscriptions', COUNT(*) FROM subscriptions
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'marketing_spend', COUNT(*) FROM marketing_spend
UNION ALL SELECT 'ab_test_assignments', COUNT(*) FROM ab_test_assignments;
-- Result: users=4000, subscriptions=574, events=217233,
--         marketing_spend=140, ab_test_assignments=4000

-- 1.2 Column types (important — subscriptions table date columns are TEXT ,
--     users  TIMESTAMP  — this mismatch solve  and cleaning  )
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;

-- 1.3 Date ranges
SELECT MIN(signup_date), MAX(signup_date) 
FROM users;

SELECT MIN(event_timestamp), MAX(event_timestamp)
FROM events;

SELECT MIN(month), MAX(month) 
FROM marketing_spend;

-- 1.4 Distinct categorical values (typos / check  case issues )
SELECT DISTINCT acquisition_channel FROM users ORDER BY 1;

SELECT DISTINCT country FROM users ORDER BY 1;

SELECT DISTINCT device_type FROM users ORDER BY 1;

SELECT DISTINCT plan FROM subscriptions ORDER BY 1;

SELECT DISTINCT event_name FROM events ORDER BY 1;

-- 1.5 events table how much ivent type and how much more time event
SELECT event_name, COUNT(*) AS cnt
FROM events GROUP BY 1 ORDER BY 2 DESC;

/* RESULT

  feature_used                        144230
  session_start                        57780
  sign_up                               4000
  onboarding_step_1_profile             4000
  onboarding_step_2_use_case            3283
  onboarding_step_3_invite_team         2220
  activation_created_first_project      1369
  plan_upgraded                          287
  subscription_cancelled                  63
  plan_downgraded                          1
*/


/* ============================================================================
   STEP 2 — DATA QUALITY AUDIT ( actual issues find after, testing table)
   ============================================================================

   Good point : users, events, marketing_spend tables are actually good  —Becouse
   not NULL user_id, not duplicate event_id, not orphan record .
   but 3 real issues so importand to clean data for perform :

   ISSUE #1 — subscriptions table sparse 
   -----------------------------------------
   SELECT DISTINCT user_id  FROM subscriptions ;
   SELECT DISTINCT *  FROM users; 
   Present 4000 users , but subscriptions table only 283 distinct user_id
    (574 rows, becose plan-change history store  — so one user multiple row present :
	Free -> Starter -> Pro).
   Means 3717 users (~93%) not subscription record create —
   this user mostly step signup + onboarding but not plan select , they only  trial steps
   .SO INNER JOIN use to 93% users silently drop .

   ISSUE #2 — events.plan_at_event  33% NULL
   ---------------------------------------------
 (  SELECT  * FROM events
where event_id is null or user_id is null or event_timestamp is null
or event_name is null or session_id is null or feature_name is null 
or plan_at_event is null )

after query

-- 73003 null both feature_name ,plan_at_event  
  in a 217,233 events row  72,652 rows are plan_at_event is  NULL . this column
   plan-based segmentation (e.g. "Free users how much feature basiclly use")
   is important for, so NULL   handle requirement  —
   Directly group by plan_at_event will push a large chunk into the "unknown" bucket
   if left untreated.


   ISSUE #3 — Mixed date types
   ----------------------------
 (  SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;)
after query

   users.signup_date  -> TIMESTAMP
   subscriptions.start_date / end_date -> TEXT
   Join/date-math use time  explicit :: becouse date cast Have to use it,
   otherwise the comparison will silently fail with wrong results or an error."

   (Extra note, bug not: acquisition_cost = 0 for Organic Search/Content-SEO
   rows — this is currect becose organic chennels not  track per user cost .
   However, the marketing_spend table also includes spending on these channels (content creation, SEO tools).
   While calculating CAC, this difference needs to be kept in mind, as shown in Step 7."
   ============================================================================ */
   
-- 2.1 Verify Issue #1
SELECT COUNT(*) AS users_without_subscription
FROM users u LEFT JOIN subscriptions s ON u.user_id = s.user_id
WHERE s.user_id IS NULL;
-- 3717

-- 2.2 Verify Issue #2
SELECT
  COUNT(*) FILTER (WHERE plan_at_event IS NULL) AS null_plan_events,
  COUNT(*) AS total_events,
  ROUND(100.0 * COUNT(*) FILTER (WHERE plan_at_event IS NULL) / COUNT(*), 1) AS pct_null
FROM events;

-- result null_plan_events 72652	,total_events  217233 ,pct_null	33.4

-- 2.3 Standard sanity checks (re check to conform null value not find )
SELECT COUNT(*) - COUNT(DISTINCT user_id) AS duplicate_users FROM users; ---0

SELECT COUNT(*) FROM events e
LEFT JOIN users u ON e.user_id = u.user_id
WHERE u.user_id IS NULL; --0(orphan events) 

SELECT COUNT(*) - COUNT(DISTINCT event_id) AS duplicate_events 
FROM events;

SELECT COUNT(*) FROM subscriptions
WHERE end_date IS NOT NULL AND end_date <> '' AND end_date::date < start_date::date; -- end before start


/* ============================================================================
   STEP 3 — CLEANING (create views , becouse analytics queries use to define stakeholder )
   ============================================================================ */

-- 3.1 Clean subscriptions: proper date types
DROP VIEW IF EXISTS vw_subscriptions_clean;
CREATE VIEW vw_subscriptions_clean AS
SELECT
  user_id,
  plan,
  mrr,
  start_date::date AS start_date,
  NULLIF(end_date, '')::date AS end_date,
  (end_date IS NULL OR end_date = '') AS is_active
FROM subscriptions;

SELECT * FROM vw_subscriptions_clean


-- 3.2 Current plan per user (latest row; open subscription preferred)
--     — isview se Issue #1  effect clearly visible (LEFT JOIN zaroori)
DROP VIEW IF EXISTS vw_user_current_plan;
CREATE VIEW vw_user_current_plan AS
SELECT DISTINCT ON (user_id)
  user_id, plan, mrr, start_date AS plan_start_date, end_date AS plan_end_date, is_active
FROM vw_subscriptions_clean
ORDER BY user_id, is_active DESC, start_date DESC;

-- 3.3 Users master with current plan attached (Free/Never-subscribed both cover)
DROP VIEW IF EXISTS vw_users_enriched;
CREATE VIEW vw_users_enriched AS
SELECT
  u.user_id, u.signup_date, u.acquisition_channel, u.acquisition_cost,
  u.country, u.device_type, u.signup_quality_score,
  COALESCE(p.plan, 'No Subscription') AS current_plan,
  COALESCE(p.mrr, 0) AS current_mrr,
  COALESCE(p.is_active, false) AS has_active_subscription
FROM users u
LEFT JOIN vw_user_current_plan p ON p.user_id = u.user_id;

-- 3.4 Events cleaned (Issue #2 fix: NULL plan_at_event -> 'Unknown', explicit)
DROP VIEW IF EXISTS vw_events_clean;
CREATE VIEW vw_events_clean AS
SELECT
  event_id, user_id, event_timestamp, event_name, session_id, feature_name,
  COALESCE(plan_at_event, 'Unknown') AS plan_at_event
FROM events;

-- Quick check

SELECT * FROM vw_users_enriched LIMIT 5;

SELECT current_plan, COUNT(*) FROM vw_users_enriched GROUP BY 1 ORDER BY 2 DESC;


/* ============================================================================
   STEP 4 — DAU / WAU / MAU
   ============================================================================ */

-- 4.1 Daily Active Users
SELECT event_timestamp::date AS day, COUNT(DISTINCT user_id) AS dau
FROM vw_events_clean
GROUP BY 1
ORDER BY dau desc;

-- 4.2 Weekly Active Users (calendar week bucket)
SELECT date_trunc('week', event_timestamp)::date AS week_start,
       COUNT(DISTINCT user_id) AS wau
FROM vw_events_clean
GROUP BY 1
ORDER BY wau desc;

-- 4.3 Monthly Active Users (calendar month bucket)
SELECT date_trunc('month', event_timestamp)::date AS month_start,
       COUNT(DISTINCT user_id) AS mau
FROM vw_events_clean
GROUP BY 1
ORDER BY mau desc;

-- 4.4 Rolling (trailing) WAU/MAU per day + DAU/MAU stickiness ratio
--     Stickiness ratio batata hai product kitna "sticky" hai (0.2 achha maana jata hai)
WITH days AS (
  SELECT generate_series(
    (SELECT MIN(event_timestamp)::date FROM vw_events_clean),
    (SELECT MAX(event_timestamp)::date FROM vw_events_clean),
    '1 day'::interval
  )::date AS day
)
SELECT
  d.day,
  (SELECT COUNT(DISTINCT user_id) FROM vw_events_clean e WHERE e.event_timestamp::date = d.day) AS dau,
  (SELECT COUNT(DISTINCT user_id) FROM vw_events_clean e WHERE e.event_timestamp::date BETWEEN d.day - 6 AND d.day) AS rolling_wau,
  (SELECT COUNT(DISTINCT user_id) FROM vw_events_clean e WHERE e.event_timestamp::date BETWEEN d.day - 29 AND d.day) AS rolling_mau,
  ROUND(
    (SELECT COUNT(DISTINCT user_id) FROM vw_events_clean e WHERE e.event_timestamp::date = d.day)::numeric /
    NULLIF((SELECT COUNT(DISTINCT user_id) FROM vw_events_clean e WHERE e.event_timestamp::date BETWEEN d.day - 29 AND d.day), 0)
  , 3) AS dau_mau_stickiness
FROM days d
ORDER BY d.day;


/* ============================================================================
   STEP 5 — FUNNEL ANALYSIS
   (sign_up -> profile -> use_case -> invite_team -> activation)
   ============================================================================ */

WITH step_order AS (
  SELECT * FROM (VALUES
    ('sign_up', 1),
    ('onboarding_step_1_profile', 2),
    ('onboarding_step_2_use_case', 3),
    ('onboarding_step_3_invite_team', 4),
    ('activation_created_first_project', 5)
  ) AS t(event_name, step_num)
),
user_first_event AS (
  -- for every user first step  occurrence (ordering ke against safe) 
  SELECT e.user_id, so.step_num, MIN(e.event_timestamp) AS first_ts
  FROM vw_events_clean e
  JOIN step_order so ON so.event_name = e.event_name  
  GROUP BY e.user_id, so.step_num   
),
funnel_counts AS (
  SELECT step_num, COUNT(DISTINCT user_id) AS users_reached
  FROM user_first_event
  GROUP BY step_num
)
SELECT
  so.step_num,
  so.event_name AS funnel_step,
  fc.users_reached,
  ROUND(100.0 * fc.users_reached / FIRST_VALUE(fc.users_reached) OVER (ORDER BY so.step_num), 1) AS pct_of_total_signups,
  ROUND(100.0 * fc.users_reached / LAG(fc.users_reached) OVER (ORDER BY so.step_num), 1) AS pct_of_previous_step
FROM step_order so
JOIN funnel_counts fc ON fc.step_num = so.step_num
ORDER BY so.step_num;
/*
  Result (test run se):
  1 sign_up                          4000  100.0%   --
  2 onboarding_step_1_profile        4000  100.0%   100.0%
  3 onboarding_step_2_use_case       3283   82.1%    82.1%
  4 onboarding_step_3_invite_team    2220   55.5%    67.6%
  5 activation_created_first_project 1369   34.2%    61.7%

  Sabse bada drop-off: step 3 -> 4 (invite_team), sirf 67.6% aage badhte hain.
*/

-- 5.1 Funnel by acquisition channel (optional cut — kaunsa channel best converts)
WITH step_order AS (
  SELECT * FROM (VALUES
    ('sign_up', 1), ('activation_created_first_project', 5)
  ) AS t(event_name, step_num)
),
user_first_event AS (
  SELECT e.user_id, so.step_num
  FROM vw_events_clean e JOIN step_order so ON so.event_name = e.event_name
  GROUP BY e.user_id, so.step_num
)
SELECT u.acquisition_channel,
  COUNT(DISTINCT u.user_id) FILTER (WHERE ufe.step_num = 1) AS signups,
  COUNT(DISTINCT u.user_id) FILTER (WHERE ufe.step_num = 5) AS activated,
  ROUND(100.0 * COUNT(DISTINCT u.user_id) FILTER (WHERE ufe.step_num = 5)
        / NULLIF(COUNT(DISTINCT u.user_id) FILTER (WHERE ufe.step_num = 1), 0), 1) AS activation_rate_pct
FROM vw_users_enriched u
JOIN user_first_event ufe ON ufe.user_id = u.user_id
GROUP BY u.acquisition_channel
ORDER BY activation_rate_pct DESC;

-- RESULT: CHANNEL-WISE ACTIVATION RATE ANALYSIS

-- acquisition_channel  | signups | activated | activation_rate_pct
-- ----------------------------------------------------------------------------
-- Paid Search          | 739     | 270       | 36.5%
-- Email                | 413     | 147       | 35.6%
-- Paid Social          | 642     | 224       | 34.9%
-- Content/SEO          | 493     | 169       | 34.3%
-- Referral             | 575     | 193       | 33.6%
-- Organic Search       | 796     | 261       | 32.8%
-- Affiliate            | 342     | 105       | 30.7%
--
-- KEY INSIGHTS & BUSINESS TAKEAWAYS:
-- 1. Top Performers: Paid Search (36.5%) and Email (35.6%) deliver the highest quality high-intent users.
-- 2. High Volume, Low Conversion: Organic Search brings the most signups (796) but lags in activation (32.8%).
-- 3. Weakest Channel: Affiliate brings lowest volume (342) and lowest activation rate (30.7%).
-- 4. Strategic Action: Reallocate marketing budget toward Paid Search/Social and optimize onboarding for Organic traffic.
-- ============================================================================

/* ============================================================================
   STEP 6 — COHORT RETENTION (monthly signup cohorts)
   ============================================================================ */

-- 6.1 Detailed cohort table (cohort_month x month_number)
WITH cohort AS (
  SELECT user_id, date_trunc('month', signup_date)::date AS cohort_month
  FROM vw_users_enriched
),
activity AS (
  SELECT DISTINCT user_id, date_trunc('month', event_timestamp)::date AS activity_month
  FROM vw_events_clean
),
cohort_activity AS (
  SELECT
    c.cohort_month,
    (DATE_PART('year', a.activity_month) - DATE_PART('year', c.cohort_month)) * 12
      + (DATE_PART('month', a.activity_month) - DATE_PART('month', c.cohort_month)) AS month_number,
    c.user_id
  FROM cohort c
  JOIN activity a ON a.user_id = c.user_id AND a.activity_month >= c.cohort_month
),
cohort_size AS (
  SELECT cohort_month, COUNT(DISTINCT user_id) AS num_users
  FROM cohort GROUP BY 1
)
SELECT
  ca.cohort_month,
  cs.num_users AS cohort_size,
  ca.month_number,
  COUNT(DISTINCT ca.user_id) AS active_users,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) / cs.num_users, 1) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
GROUP BY ca.cohort_month, cs.num_users, ca.month_number
ORDER BY ca.cohort_month, ca.month_number;

-- 6.2 Pivoted version (report-friendly: month_0 to month_6 as columns)
WITH cohort AS (
  SELECT user_id, date_trunc('month', signup_date)::date AS cohort_month
  FROM vw_users_enriched
),
activity AS (
  SELECT DISTINCT user_id, date_trunc('month', event_timestamp)::date AS activity_month
  FROM vw_events_clean
),
cohort_activity AS (
  SELECT c.cohort_month,
         (DATE_PART('year', a.activity_month) - DATE_PART('year', c.cohort_month)) * 12
           + (DATE_PART('month', a.activity_month) - DATE_PART('month', c.cohort_month)) AS month_number,
         c.user_id
  FROM cohort c JOIN activity a ON a.user_id = c.user_id AND a.activity_month >= c.cohort_month
),
cohort_size AS (SELECT cohort_month, COUNT(DISTINCT user_id) AS num_users FROM cohort GROUP BY 1)
SELECT
  ca.cohort_month, cs.num_users,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) FILTER (WHERE month_number = 0) / cs.num_users, 1) AS month_0,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) FILTER (WHERE month_number = 1) / cs.num_users, 1) AS month_1,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) FILTER (WHERE month_number = 2) / cs.num_users, 1) AS month_2,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) FILTER (WHERE month_number = 3) / cs.num_users, 1) AS month_3,
  ROUND(100.0 * COUNT(DISTINCT ca.user_id) FILTER (WHERE month_number = 6) / cs.num_users, 1) AS month_6
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
GROUP BY ca.cohort_month, cs.num_users
ORDER BY ca.cohort_month;


/* ============================================================================
   STEP 7 — CAC & CLV
   ============================================================================ */

-- 7.1 CAC — Method A: users.acquisition_cost se direct average (per-user cost)
SELECT acquisition_channel,
       COUNT(*) AS users_acquired,
       ROUND(SUM(acquisition_cost)::numeric, 2) AS total_cost,
       ROUND(AVG(acquisition_cost)::numeric, 2) AS cac
FROM vw_users_enriched
GROUP BY acquisition_channel
ORDER BY cac DESC;
-- 7.2 CAC — Method B: marketing_spend table se (zyada accurate — organic
--     channels ka indirect spend bhi capture karta hai jo Method A me 0 dikhta hai)
WITH monthly_new_users AS (
  SELECT acquisition_channel AS channel,
         to_char(signup_date, 'YYYY-MM-01') AS month,
         COUNT(*) AS new_users
  FROM vw_users_enriched
  GROUP BY 1, 2
)
SELECT ms.month, ms.channel, ms.marketing_spend, mnu.new_users,
       ROUND((ms.marketing_spend / NULLIF(mnu.new_users, 0))::numeric, 2) AS cac_from_spend
FROM marketing_spend ms
JOIN monthly_new_users mnu ON mnu.channel = ms.channel AND mnu.month = ms.month
ORDER BY ms.month, ms.channel;

-- 7.3 CLV — total revenue generated per user (mrr x months on that plan),
--     phir channel-wise average CLV (do variants: per signup vs per paying user)
WITH sub_months AS (
  SELECT user_id, mrr,
    GREATEST(
      1,
      DATE_PART('year', AGE(COALESCE(end_date::date, CURRENT_DATE), start_date::date)) * 12
      + DATE_PART('month', AGE(COALESCE(end_date::date, CURRENT_DATE), start_date::date))
    ) AS months_active
  FROM subscriptions
),
user_revenue AS (
  SELECT user_id, SUM(mrr * months_active) AS total_revenue
  FROM sub_months
  GROUP BY user_id
),
channel_stats AS (
  SELECT u.acquisition_channel,
         COUNT(DISTINCT u.user_id) AS total_users,
         COUNT(DISTINCT ur.user_id) AS paying_users,
         ROUND(AVG(u.acquisition_cost)::numeric, 2) AS avg_cac,
         ROUND((COALESCE(SUM(ur.total_revenue), 0) / COUNT(DISTINCT u.user_id))::numeric, 2) AS avg_clv_per_signup,
         ROUND((COALESCE(SUM(ur.total_revenue), 0) / NULLIF(COUNT(DISTINCT ur.user_id), 0))::numeric, 2) AS avg_clv_per_paying_user
  FROM vw_users_enriched u
  LEFT JOIN user_revenue ur ON ur.user_id = u.user_id
  GROUP BY u.acquisition_channel
)
SELECT *,
  CASE WHEN avg_cac > 0 THEN ROUND(avg_clv_per_signup / avg_cac, 2) ELSE NULL END AS ltv_cac_ratio
FROM channel_stats
ORDER BY ltv_cac_ratio DESC NULLS LAST;
/*
  Result (test run se) — yeh sabse important business insight hai:

  channel          cac     clv/signup   ltv:cac
  Email             3.18      11.83       3.72   <- best
  Referral          5.02      18.13       3.61   <- best
  Paid Social      28.03      20.40       0.73   <- LOSING money
  Affiliate        19.97      11.08       0.55   <- LOSING money
  Paid Search      35.49      13.81       0.39   <- worst, LOSING money

  Rule of thumb: LTV:CAC >= 3 healthy hota hai. Paid Search aur Affiliate
  par spend zyada hai lekin return kam — inko optimize/cut karne ka case ban
  raha hai, jabki Email/Referral underinvested lag rahe hain.
*/