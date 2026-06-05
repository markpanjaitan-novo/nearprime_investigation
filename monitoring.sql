---------------------------MCA------------------------------
--MCA Principal Balance
select
 to_char(snap_date-1,'YYYY-MM') as report_mth,
 case
 when application_cohort between '2024-09' and '2025-08' then 'CCR V1'
 when application_cohort >= '2025-09' then 'CCR V2'
 else 'Pre-CCR'
 end as underwriting_vintage,
 sum(principal_balance_outstanding) as outstanding_balance,
 sum(factor_fee_amount_paid_last_month) as factor_fee_collected,
 sum(fee_amount_paid_last_month) as late_fee_collected,
 sum(gross_principal_amount_charged_off)+sum(case when days_past_due between 180 and 210 then principal_balance_outstanding end) as gaco
from prod_db.data.loan_tape
where 1=1
and day(snap_date) = 1 --or snap_date in (select max(snap_date) from prod_db.data.loan_tape)
and days_past_due <= 210
and snap_date >= '2024-02-01'
group by 1,2
order by 1 desc,2
;


--mca c-x0
with rollrate_data as (
select
 to_char(snap_date-1,'YYYY-MM') as report_mth
,sum(case when days_past_due = 0 then principal_balance_outstanding end) as bucket_0_dollar_amount
,sum(case when days_past_due between 1 and 29 then principal_balance_outstanding end) as bucket_1_dollar_amount
,sum(case when days_past_due between 30 and 59 then principal_balance_outstanding end) as bucket_2_dollar_amount
,sum(case when days_past_due between 60 and 89 then principal_balance_outstanding end) as bucket_3_dollar_amount
,sum(case when days_past_due between 90 and 119 then principal_balance_outstanding end) as bucket_4_dollar_amount
,sum(case when days_past_due between 120 and 149 then principal_balance_outstanding end) as bucket_5_dollar_amount
,sum(case when days_past_due between 150 and 179 then principal_balance_outstanding end) as bucket_6_dollar_amount
,sum(case when days_past_due between 180 and 210 then principal_balance_outstanding + gross_principal_amount_charged_off end) as bucket_7_dollar_amount
from prod_db.data.loan_tape
where day(snap_date) = 1
and days_past_due <= 210
group by 1
order by 1
)
select
 report_mth
,bucket_0_dollar_amount
,bucket_1_dollar_amount
,bucket_2_dollar_amount
,bucket_3_dollar_amount
,bucket_4_dollar_amount
,bucket_5_dollar_amount
,bucket_6_dollar_amount
,bucket_7_dollar_amount
from rollrate_data
where report_mth >= '2024-10'
;


--mca response & drawn rate
with latest_loan_tape as (
select
 business_id
,sum(principal_balance_outstanding) as balance_outstanding
from prod_db.data.loan_tape
where snap_date in (select max(snap_date) from prod_db.data.loan_tape)
group by 1
)
select
 to_char(a.created_at,'YYYY-MM') as invite_mth
,trim(a.meta:inputVariables:CCR_BIN) as risk_bin
,count(distinct a.business_id) as inv_vol
,count(distinct case when c.is_offer_accepted is not null and c.application_status = 'approved' then a.id end) as accepted_vol
,count(distinct d.business_id) as drawn_vol
from fivetran_db.prod_novo_api_public.lending_invitations a
left join fivetran_db.prod_novo_api_public.lending_businesses c
on a.business_id = c.business_id
and a.id = c.lending_invitation_id
left join latest_loan_tape d
on a.business_id = d.business_id
and d.balance_outstanding > 0
where to_char(a.created_at,'YYYY-MM') >= '2025-09'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
union all
select
 to_char(a.created_at,'YYYY-MM') as invite_mth
,'Aggregate' as risk_bin
,count(distinct a.business_id) as inv_vol
,count(distinct case when c.is_offer_accepted is not null and c.application_status = 'approved' then a.id end) as accepted_vol
,count(distinct d.business_id) as drawn_vol
from fivetran_db.prod_novo_api_public.lending_invitations a
left join fivetran_db.prod_novo_api_public.lending_businesses c
on a.business_id = c.business_id
and a.id = c.lending_invitation_id
left join latest_loan_tape d
on a.business_id = d.business_id
and d.balance_outstanding > 0
where to_char(a.created_at,'YYYY-MM') >= '2025-09'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
order by 1,2
;



--mca first-time vs net-new invitation distro
with first_invite as (
select
 created_at
,business_id
,row_number() over (partition by business_id order by created_at asc) as rn
from fivetran_db.prod_novo_api_public.lending_invitations
)
select
 to_char(a.created_at,'YYYY-MM') as invite_date
,case when b.created_at = a.created_at then 'first-time' else 'repeat' end as invite_type
,count(distinct a.business_id) as invites_sent
,count(distinct c.business_id) as accepted_count
from fivetran_db.prod_novo_api_public.lending_invitations a
left join (select * from first_invite where rn = 1) b
on a.business_id = b.business_id
left join fivetran_db.prod_novo_api_public.lending_businesses c
on a.id = c.lending_invitation_id
and c.offer_accepted_at > a.created_at
where (invite_date >= '2025-03' or invite_date >= '2025-06')
and invite_date != '2025-08'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
order by 1 desc,2
;



--mca ccr v2 decile 10 price test
with latest_loan_tape as (
select
 business_id
,sum(principal_balance_outstanding) as balance_outstanding
from prod_db.data.loan_tape
where snap_date in (select max(snap_date) from prod_db.data.loan_tape)
group by 1
)
,distro as (
select
 -- to_char(a.created_at,'YYYY-MM') as invite_mth
 trim(a.meta:inputVariables:CCR_BIN) as risk_bin
,round(a.apr/12,2) as factor_rate
,count(distinct a.business_id) as inv_vol
,count(distinct c.business_id) as accepted_vol
,count(distinct d.business_id) as drawn_vol
from fivetran_db.prod_novo_api_public.lending_invitations a
left join fivetran_db.prod_novo_api_public.lending_businesses c
on a.business_id = c.business_id
and c.lending_invitation_id = a.id
left join latest_loan_tape d
on a.business_id = d.business_id
and d.balance_outstanding > 0
where to_char(a.created_at,'YYYY-MM') between '2025-09' and '2025-12'
-- and c.offer_accepted_at > '2025-09-02'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and risk_bin = 10
group by 1,2
order by 1,2
)
,balance as (
select
 trim(c.meta:inputVariables:CCR_BIN) as ccr_v2_decile
,a.monthly_factor_rate
,count(distinct a.business_id) as drawn_vol
,sum(a.principal_balance_outstanding) as principal_outstanding
from prod_db.data.loan_tape a
left join fivetran_db.prod_novo_api_public.lending_businesses b
on a.business_id = b.business_id
left join fivetran_db.prod_novo_api_public.lending_invitations c
on b.lending_invitation_id = c.id
where a.application_cohort >= '2025-09'
and b.offer_accepted_at > '2025-09-02'
and snap_date in (select max(snap_date) from prod_db.data.loan_tape)
and ccr_v2_decile = 10
group by 1,2
order by 1,2
)
select
 a.*
,b.* exclude ccr_v2_decile
from distro a
left join balance b
on a.factor_rate = b.monthly_factor_rate
where a.factor_rate in (3.25,3.75)
;


--MCA origination
with first_snap as (
select
*
,row_number() over (partition by loan_id order by snap_date asc) as rn
from prod_db.data.loan_tape
where to_char(advance_date,'YYYY-MM') >= '2024-01'
),
payment as (
select
to_char(created_at,'YYYY-MM') as payment_mth,
round(sum(amount)/100,2) as payment
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_TRANSACTIONS
where type = 'cash_in'
and payment_mth >= '2024-01'
group by 1
),
final as (
select
to_char(advance_date,'YYYY-MM') as orig_mth,
day(last_day(advance_date)) as mth_duration,
sum(original_receivable_balance) as orig_total,
orig_total/mth_duration as avg_draw_amount_per_day,
count(distinct business_id) as active_vol,
count(distinct loan_id) as draw_count,
draw_count/mth_duration as avg_draw_count_per_day,
avg_draw_amount_per_day/avg_draw_count_per_day as avg_draw_amount_per_draw
from (select * from first_snap where rn = 1)
where 1=1
and business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
)
select
 a.*
,b.payment
,b.payment/a.mth_duration as avg_payment_per_day
from final a
left join payment b
on a.orig_mth = b.payment_mth
where a.orig_mth < to_char(current_date,'YYYY-MM')
order by 1,2
;


--MCA principal payment ratio (principal payments received during month / beginning of month principal balance)
select
 to_char(snap_date-1,'YYYY-MM') as report_mth
,sum(principal_amount_paid_last_month) as principal_received
,sum(principal_balance_outstanding) as principal_outstanding
,case
 when report_mth = '2023-03' then 7937863.18
 else lag(principal_outstanding) over (order by report_mth)
 end as beginning_principal_balance
from prod_db.data.loan_tape
where day(snap_date) = 1
and report_mth >= '2023-03'
group by 1
order by 1
;

 
--MCA yield collected during the month in the roll forward (e.g. interest, interchange, fees)
with active_vol as (
select
 to_char(snap_date-1,'YYYY-MM') as report_mth
,count(distinct business_id) as active_vol
from prod_db.data.loan_tape
where day(snap_date) = 1
and report_mth >= '2023-03'
and principal_balance_outstanding > 0
group by 1
order by 1
)
,yield_collected as (
select
 to_char(snap_date-1,'YYYY-MM') as report_mth
,sum(factor_fee_amount_paid_last_month) as factor_fee_collected
,sum(fee_amount_paid_last_month) as late_fee_collected
from prod_db.data.loan_tape
where day(snap_date) = 1
and report_mth >= '2023-03'
group by 1
order by 1
)
select
 a.*
,b.active_vol
from yield_collected a
left join active_vol b
on a.report_mth = b.report_mth
order by 1
; 


--MCA COC by application cohort
with monthly_collection as (
select
 business_id
,loan_id
,application_cohort
,to_char(advance_date,'YYYY-MM') as draw_mth
,to_char(snap_date-1,'YYYY-MM') as collection_mth
,row_number() over (partition by loan_id, draw_mth order by collection_mth asc) as rank_collection_mth
,total_principal_collected + total_factor_fee_collected + total_late_fees_collected as cash_rec_total
,original_receivable_balance as origination_total
from prod_db.data.loan_tape
where 1=1
and date_part(day,snap_date::date) = 1
and datediff(month,advance_date,snap_date) between 2 and 9
and to_char(advance_date,'YYYY-MM') >= application_cohort
and business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
order by collection_mth desc
)
select
 application_cohort
,rank_collection_mth
,sum(cash_rec_total) as cash_rec_total
,sum(origination_total) as orig_total
,sum(cash_rec_total)/sum(origination_total) as coc_rec_rate
,count(distinct business_id) as acct_vol
,count(distinct loan_id) as draw_count
from monthly_collection
where application_cohort >= to_char(dateadd(month,-15,current_date))
group by 1,2
order by 1,2 asc
;


----booking vintage----
with per_orig as (
select
 to_char(a.offer_accepted_at,'YYYY-MM') as booking_month
,count(distinct business_id) as acct_vol_orig
,round(sum(a.credit_limit/100)) as total_credit_limit
from fivetran_db.prod_novo_api_public.lending_businesses a
group by 1
)
,loan_tape as (
select
 to_char(a.offer_accepted_at,'YYYY-MM') as booking_month
,datediff(month,a.offer_accepted_at,b.snap_date-1) as booking_statement_no
,sum(b.principal_balance_outstanding) as principal_outstanding
,sum(b.factor_fee_amount_paid_last_month) as factor_fee_collected
,sum(b.late_fees_recovered_last_month) as late_fee_collected
,sum(case when b.days_past_due between 180 and 209 then b.gross_principal_amount_charged_off else 0 end) as gaco
,count(case when b.days_past_due between 30 and 209 then b.business_id end) as dq30plus_acct_vol
,sum(case when b.days_past_due between 30 and 209 then b.principal_balance_outstanding else 0 end) as dq30plus_balance
,count(case when b.days_past_due between 60 and 209 then b.business_id end) as dq60plus_acct_vol
,sum(case when b.days_past_due between 60 and 209 then b.principal_balance_outstanding else 0 end) as dq60plus_balance
,count(case when b.days_past_due between 180 and 209 then b.business_id end) as co_acct_vol
from fivetran_db.prod_novo_api_public.lending_businesses a
left join prod_db.data.loan_tape b
on a.business_id = b.business_id
and day(b.snap_date) = 1
where a.offer_accepted_at is not null
and booking_statement_no > 0
and booking_month >= '2024-09'
group by 1,2
order by 1,2
)
select
 a.* exclude co_acct_vol
,b.acct_vol_orig
,b.total_credit_limit
,sum(a.co_acct_vol) over (partition by a.booking_month order by a.booking_statement_no asc) as cum_co_acct_vol
,sum(a.gaco) over (partition by a.booking_month order by a.booking_statement_no asc) as cum_gaco
,sum(a.factor_fee_collected) over (partition by a.booking_month order by a.booking_statement_no asc) as cum_factor_fee_collected
,sum(a.late_fee_collected) over (partition by a.booking_month order by a.booking_statement_no asc) as cum_late_fee_collected
from loan_tape a
left join per_orig b
on a.booking_month = b.booking_month
;



---------------------------CC------------------------------
------CREDIT CARD-----------
--portfolio snapshot
with most_recent_invite as ( 
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
co_account as (
select
 distinct business_id
from (select * from loan_tape_updated where rn = 1)
where days_past_due = 181
),
interest_and_fees as (
select
 business_id
,sum(case when days_past_due > 181 then 0 else payment_allocated_interest end) as interest_rev
,sum(case when days_past_due > 181 then 0 else payment_allocated_fees end) as fee_rev
from (select * from loan_tape_updated where rn = 1)
where to_char(statement_date,'YYYY-MM') = to_char(dateadd(month,-1,current_date),'YYYY-MM')
group by 1
),
interchange as (
select
 b.business_id
,sum(a.interchange_gross_amount*-1) as interchange_rev
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS a
left join fivetran_db.prod_novo_api_public.credit_card_accounts b
on a.credit_card_account_id = b.id
where to_char(a.created_at,'YYYY-MM') = to_char(dateadd(month,-1,current_date),'YYYY-MM')
group by 1
),
rewards_accrued as (
select
 b.business_id
,sum(a.rewards) as reward_accrued
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS a
left join fivetran_db.prod_novo_api_public.credit_card_accounts b
on a.credit_card_account_id = b.id
where to_char(a.created_at,'YYYY-MM') = to_char(dateadd(month,-1,current_date),'YYYY-MM')
group by 1
)
select
 statement_date as report_mth
,sum(case when days_past_due <= 210 then ending_balance end/100) as os_total --Total Outstanding Balance
,sum(case when days_past_due = 0 then ending_balance/100 end) as current_os_total
,sum(case when days_past_due between 1 and 29 then ending_balance/100 end) as bucket1_os_total
,sum(case when days_past_due between 30 and 59 then ending_balance/100 end) as bucket2_os_total
,sum(case when days_past_due between 60 and 210 then ending_balance/100 end) as bucket3plus_os_total
,sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as co_dollar_total
,count(distinct a.business_id) - count(case when days_past_due >= 180 then a.business_id end) as open_vol
,count(case when days_past_due = 0 then a.business_id end) as current_acct_total
,count(case when days_past_due between 1 and 29 then a.business_id end) as bucket1_acct_total
,count(case when days_past_due between 30 and 59 then a.business_id end) as bucket2_acct_total
,count(case when days_past_due between 60 and 210 then a.business_id end) as bucket3plus_acct_total
,count(case when days_past_due between 180 and 210 then a.business_id end) as co_acct_total
,round(avg(fico_score)) as avg_fico
,round(median(fico_score)) as median_fico
,avg(EFFECTIVE_APR_PURCHASES) as avg_apr
,sum(ending_balance)/sum(credit_limit) as util
,sum(case when datediff(day,created_at,statement_date) >= 46 and grace_period = 'false' and billing_period_number >= 2 then daily_balance_purchases end)/sum(case when datediff(day,created_at,statement_date) >= 46 and billing_period_number >= 2 then daily_balance_purchases end) as rev_rate
,sum(case when f.business_id is not null then 0 else c.interest_rev end/100) as interest_rev
,sum(d.interchange_rev/100) as interchange_rev
,sum(case when f.business_id is not null then 0 else c.fee_rev end/100) as fee_rev
,sum(e.reward_accrued*-1/100) as reward_accrued
from (select * from loan_tape_updated where rn = 1) a
left join booking_date b
on a.business_id = b.business_id
left join interest_and_fees c
on a.business_id = c.business_id
left join interchange d
on a.business_id = d.business_id
left join rewards_accrued e
on a.business_id = e.business_id
left join co_account f
on a.business_id = f.business_id
where billing_period_number >= 1
and to_char(b.created_at,'YYYY-MM') < to_char(current_date,'YYYY-MM')
and statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
and datediff(month,statement_date,current_date) = 1
group by 1
order by 1
;


--principal balance outstanding by dq bucket & fico bin (+ util)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
,loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
)
select
 to_char(statement_date,'YYYY-MM') as report_mth
,case
 when days_past_due = 0 then 'current'
 when days_past_due between 1 and 29 then 'bucket 1'
 when days_past_due between 30 and 59 then 'bucket 2'
 when days_past_due between 60 and 89 then 'bucket 3'
 when days_past_due between 90 and 119 then 'bucket 4'
 when days_past_due between 120 and 149 then 'bucket 5'
 when days_past_due between 150 and 179 then 'bucket 6'
 when days_past_due between 180 and 210 then 'bucket 7'
 end as dq_bucket
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(next_due_principal+past_statements_principal+due_principal+past_due_principal)/100,2) as principal_balance_outstanding
,count(distinct business_id) as open_vol
,round(sum(credit_limit)/100,2) as total_credit_limit
,count(case when days_past_due >= 30 then business_id end) as bad_vol
,round(sum(case when days_past_due >= 30 then next_due_principal+past_statements_principal+due_principal+past_due_principal else 0 end)/100,2) as bad_principal_balance_outstanding
,round(sum(case when days_past_due >= 30 then credit_limit else 0 end)/100,2) as bad_total_credit_limit
,round(sum(case when daily_balance_purchases > 0 then credit_limit end)/100,2) as total_credit_limit_active
from (select * from loan_tape_updated where rn = 1)
where 1=1
and statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
and report_mth < to_char(current_date,'YYYY-MM')
and dq_bucket is not null
group by 1,2,3
union all
select
 to_char(statement_date,'YYYY-MM') as report_mth
,case
 when days_past_due = 0 then 'current'
 when days_past_due between 1 and 29 then 'bucket 1'
 when days_past_due between 30 and 59 then 'bucket 2'
 when days_past_due between 60 and 89 then 'bucket 3'
 when days_past_due between 90 and 119 then 'bucket 4'
 when days_past_due between 120 and 149 then 'bucket 5'
 when days_past_due between 150 and 179 then 'bucket 6'
 when days_past_due between 180 and 210 then 'bucket 7'
 end as dq_bucket
,'aggregate' as cc_fico_bin
,round(sum(next_due_principal+past_statements_principal+due_principal+past_due_principal)/100,2) as principal_balance_outstanding
,count(distinct business_id) as open_vol
,round(sum(credit_limit)/100,2) as total_credit_limit
,count(case when days_past_due >= 30 then business_id end) as bad_vol
,round(sum(case when days_past_due >= 30 then next_due_principal+past_statements_principal+due_principal+past_due_principal else 0 end)/100,2) as bad_principal_balance_outstanding
,round(sum(case when days_past_due >= 30 then credit_limit else 0 end)/100,2) as bad_total_credit_limit
,round(sum(case when daily_balance_purchases > 0 then credit_limit end)/100,2) as total_credit_limit_active
from (select * from loan_tape_updated where rn = 1)
where 1=1
and statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
and report_mth < to_char(current_date,'YYYY-MM')
and dq_bucket is not null
group by 1,2,3
order by 1,2,3
;


--dq30-59 principal balance by booking vintage
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
,loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
,e.created_at as booking_timestamp
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
left join fivetran_db.prod_novo_api_public.credit_card_applications d
on b.business_id = d.business_id
and d.status = 'APPROVED'
left join fivetran_db.prod_novo_api_public.credit_card_application_decisions e
on d.id = e.application_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
)
select
 to_char(statement_date,'YYYY-MM') as report_mth
,to_char(booking_timestamp,'YYYY-MM') as booking_mth
,round(sum(next_due_principal+past_statements_principal+due_principal+past_due_principal)/100,2) as principal_balance_outstanding
,count(distinct business_id) as open_vol
,round(sum(credit_limit)/100,2) as total_credit_limit
,count(case when days_past_due between 30 and 59 then business_id end) as bad_vol
,round(sum(case when days_past_due between 30 and 59 then next_due_principal+past_statements_principal+due_principal+past_due_principal else 0 end)/100,2) as bad_principal_balance_outstanding
,round(sum(case when days_past_due between 30 and 59 then credit_limit else 0 end)/100,2) as bad_total_credit_limit
from (select * from loan_tape_updated where rn = 1)
where 1=1
and statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
and report_mth < to_char(current_date,'YYYY-MM')
group by 1,2
order by 1,2
;


--responses
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
select
 to_char(a.submitted_at,'YYYY-MM') as app_mth
,case
 when b.fico_score between 581 and 619 then '580-620'
 when b.fico_score between 620 and 659 then '620-660'
 when b.fico_score between 660 and 719 then '660-720'
 when b.fico_score between 720 and 779 then '720-780'
 when b.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,count(distinct a.business_id) as app_vol
from fivetran_db.prod_novo_api_public.credit_card_applications a
left join (select * from most_recent_invite where rn = 1) b
on a.business_id = b.business_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.status = 'APPROVED'
and app_mth < to_char(current_date,'YYYY-MM')
group by 1,2
order by 1,2
;


--approvals
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
select
 to_char(c.created_at,'YYYY-MM') as booking_mth,
 case
 when b.fico_score between 581 and 619 then '580-620'
 when b.fico_score between 620 and 659 then '620-660'
 when b.fico_score between 660 and 719 then '660-720'
 when b.fico_score between 720 and 779 then '720-780'
 when b.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin,
 count(distinct a.business_id) as approved_vol,
 round(sum(a.credit_limit/100)) as total_exposure
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
left join (select * from most_recent_invite where rn = 1) b
on a.business_id = b.business_id
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS c
on a.id = c.application_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.status = 'APPROVED'
and booking_mth < to_char(current_date,'YYYY-MM')
group by 1,2
order by 1 asc,2
;


--open vol by activation
with cc_bookings as (
select
 distinct a.business_id
,b.created_at as booking_timestamp
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS b
on a.id = b.application_id
where 1=1
and a.status = 'APPROVED'
and b.decision = 'APPROVED'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
),
open_flag as (
select
 distinct business_id
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARDS
where business_id in (select business_id from cc_bookings)
and is_activated = true
),
most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
select
 to_char(a.booking_timestamp,'YYYY-MM') as booking_mth
,case
 when c.fico_score between 581 and 619 then '580-620'
 when c.fico_score between 620 and 659 then '620-660'
 when c.fico_score between 660 and 719 then '660-720'
 when c.fico_score between 720 and 779 then '720-780'
 when c.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,case
 when b.business_id is not null then 'Activated'
 else 'Unactivated'
 end as activated_flag
,count(a.business_id) as acct_vol
from cc_bookings a
left join open_flag b
on a.business_id = b.business_id
left join (select * from most_recent_invite where rn = 1) c
on a.business_id = c.business_id
where booking_mth < to_char(current_date,'YYYY-MM')
group by 1,2,3
union all
select
 to_char(a.booking_timestamp,'YYYY-MM') as booking_mth
,'aggregate' as cc_fico_bin
,case
 when b.business_id is not null then 'Activated'
 else 'Unactivated'
 end as activated_flag
,count(a.business_id) as acct_vol
from cc_bookings a
left join open_flag b
on a.business_id = b.business_id
left join (select * from most_recent_invite where rn = 1) c
on a.business_id = c.business_id
where booking_mth < to_char(current_date,'YYYY-MM')
group by 1,2,3
order by 1,2,3
;


--response & approval rate
select
 to_char(a.created_at,'YYYY-MM') as invite_mth,
 'Aggregate' as cc_fico_bin,
 case
 when c.business_type = 'sole_proprietorship' then 'sole_prop'
 else 'non_sole_prop'
 end as business_type,
 count(case when b.status = 'APPROVED' and datediff(day,a.created_at,b.submitted_at) between 0 and 30 then a.business_id end) as approval_count,
 count(case when b.submitted_at is not null and datediff(day,a.created_at,b.submitted_at) between 0 and 30 then a.business_id end) as response_count,
 count(a.business_id) as invite_count
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS b
on a.business_id = b.business_id
left join prod_db.data.businesses c
on a.business_id = c.business_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and invite_mth <= to_char(dateadd(month,-1,current_date),'YYYY-MM')
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as invite_mth,
 case
 when a.fico_score between 581 and 619 then '580-620'
 when a.fico_score between 620 and 659 then '620-660'
 when a.fico_score between 660 and 719 then '660-720'
 when a.fico_score between 720 and 779 then '720-780'
 when a.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin,
 case
 when c.business_type = 'sole_proprietorship' then 'sole_prop'
 else 'non_sole_prop'
 end as business_type,
 count(case when b.status = 'APPROVED' and datediff(day,a.created_at,b.submitted_at) between 0 and 30 then a.business_id end) as approval_count,
 count(case when b.submitted_at is not null and datediff(day,a.created_at,b.submitted_at) between 0 and 30 then a.business_id end) as response_count,
 count(a.business_id) as invite_count
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS b
on a.business_id = b.business_id
left join prod_db.data.businesses c
on a.business_id = c.business_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and invite_mth <= to_char(dateadd(month,-1,current_date),'YYYY-MM')
group by 1,2,3
order by 1 asc,2,3
;


--manual review rate
select
 to_char(a.created_at,'YYYY-MM') as started_month
,case
 when decision_notes ilike '%manual%' then 'Manual'
 else 'Auto'
 end as manual_auto_flag
,count(distinct a.id) as application_count
from fivetran_db.prod_novo_api_public.credit_card_applications a
left join fivetran_db.prod_novo_api_public.credit_card_application_decisions b
on a.id = b.application_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and b.decision = 'APPROVED' 
group by 1,2
order by 1,2
;


--acct vol & balance split by TRIP
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
,loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
)
,mob3_accounts as (
select
 business_id
,max(billing_period_number) as max_statement
,min(grace_period) as transactor_flag
,max(ending_balance) as max_balance
from (select * from loan_tape_updated where rn = 1)
group by 1
)
,last_3m as (
select
 business_id
,sum(day_purchases) as pvol
from (select * from loan_tape_updated where rn = 1)
where to_char(statement_date,'YYYY-MM') between to_char(dateadd(month,-3,current_date),'YYYY-MM') and to_char(dateadd(month,-1,current_date),'YYYY-MM')
and statement_date in (select distinct last_day(statement_date) from loan_tape_updated)
and business_id in (select business_id from mob3_accounts where max_statement > 3)
group by 1
)
,flags as (
select
 a.business_id
,case
 when a.transactor_flag = true then 0
 when a.transactor_flag = false then 1
 else 0
 end as revolver_flag
,case
 when b.pvol > 0 then 1
 else 0
 end as purchase_l3m_flag
,case when max_balance > 0 then 1 else 0 end as active_flag
from mob3_accounts a
left join last_3m b
on a.business_id = b.business_id
)
select
 to_char(a.statement_date,'YYYY-MM') as report_mth
,case
 when b.revolver_flag = 0 and active_flag = 1 then 'Transactor'
 when b.revolver_flag = 1 and purchase_l3m_flag = 1 then 'Revolver'
 when active_flag = 0 then 'Inactive'
 when b.revolver_flag = 1 and purchase_l3m_flag = 0 then 'Paydown'
 end as trip_flag
,round(sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100),2) as principal_balance_outstanding
,count(distinct a.business_id) as acct_vol
,round(sum(case when a.daily_balance_purchases > 0 then a.credit_limit/100 end),2) as total_credit_limit_active
from (select * from loan_tape_updated where rn = 1) a
left join flags b
on a.business_id = b.business_id
where a.statement_date in (select distinct last_day(statement_date) from loan_tape_updated)
group by 1,2
order by 1,2
;
 


--pvol
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
,open_vol as (
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,count(a.business_id) as open_vol
,sum(open_vol) over (partition by cc_fico_bin order by report_mth asc) as cum_open_vol
from fivetran_db.prod_novo_api_public.credit_card_accounts a
left join (select * from most_recent_invite where rn = 1) b
on a.business_id = b.business_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
union all 
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,'aggregate' as cc_fico_bin
,count(a.business_id) as open_vol
,sum(open_vol) over (partition by cc_fico_bin order by report_mth asc) as cum_open_vol
from fivetran_db.prod_novo_api_public.credit_card_accounts a
left join (select * from most_recent_invite where rn = 1) b
on a.business_id = b.business_id
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
order by 1,2
),
trxn as (
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(settled_amount/100),2) as pvol
from fivetran_db.prod_novo_api_public.credit_card_transactions a
-- left join fivetran_db.prod_novo_api_public.credit_card_accounts b
-- on a.business_id = b.business_id
left join (select * from most_recent_invite where rn = 1) c
on a.business_id = c.business_id
where a.result = 'APPROVED'
and a.status = 'settled'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
union all
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,'aggregate' as cc_fico_bin
,round(sum(settled_amount/100),2) as pvol
from fivetran_db.prod_novo_api_public.credit_card_transactions a
-- left join fivetran_db.prod_novo_api_public.credit_card_invitations b
-- on a.business_id = b.business_id
left join (select * from most_recent_invite where rn = 1) c
on a.business_id = c.business_id
where a.result = 'APPROVED'
and a.status = 'settled'
and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
)
select
 a.report_mth
,a.cc_fico_bin
,a.pvol
,case
 when a.report_mth = '2025-10' and a.cc_fico_bin = '720-780' then 820
 when a.report_mth = '2025-10' and a.cc_fico_bin = '780-850' then 803
 when b.cum_open_vol is null then lead(b.cum_open_vol) over (partition by a.cc_fico_bin order by a.report_mth desc)
 else b.cum_open_vol
 end as cum_open_vol
from trxn a
left join open_vol b
on a.report_mth = b.report_mth
and a.cc_fico_bin = b.cc_fico_bin
where a.report_mth < to_char(current_date,'YYYY-MM')
order by 1,2
;


--min pay ratio
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
)
,BASE AS
(SELECT
    CS.BUSINESS_ID,
    CASE
    WHEN INV.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
    WHEN INV.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
    WHEN INV.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
    WHEN INV.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
    WHEN INV.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
    END AS CC_FICO_BIN,
    CS.CREATED_AT,
    CS.CREATED_AT::DATE AS STATEMENT_DATE,
    CS.PAYMENT_DUE_DATE,
    CS.MINIMUM_PAYMENT_DUE/100 AS MINIMUM_PAYMENT_DUE,
    CS.STATEMENT_BALANCE/100 AS STATEMENT_BALANCE,
    -- CP.CREATED_AT AS PAYMENT_DATE,
    -- CP.OPTION AS PAYMENT_TYPE,
    SUM(CP.AMOUNT/100) AS PAYMENT_AMOUNT
    
FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS AS CS
LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS AS CP ON CS.BUSINESS_ID = CP.BUSINESS_ID AND CP.CREATED_AT::DATE > CS.END_DATE::DATE AND CP.CREATED_AT::DATE <=PAYMENT_DUE_DATE::DATE
LEFT JOIN (select * from most_recent_invite where rn = 1) AS INV ON CS.BUSINESS_ID = INV.BUSINESS_ID
WHERE TRUE
AND CS.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
AND CP.AMOUNT > 0
GROUP BY ALL
ORDER BY BUSINESS_ID,PAYMENT_DUE_DATE)

,Filter as
(SELECT DISTINCT BUSINESS_ID
FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS AS CA
JOIN PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY AS LTH ON CA.EXTERNAL_ACCOUNT_ID = LTH.ACCOUNT_ID
WHERE GRACE_PERIOD = FALSE
QUALIFY row_number() over (partition by LTH.ACCOUNT_ID, LTH.statement_date order by LTH.record_version desc) = 1 )

SELECT DATE_TRUNC('MONTH',STATEMENT_DATE) AS STATEMENT_MONTH, 'aggregate' as CC_FICO_BIN, AVG(MIN_PAY_RATIO) as MIN_PAY_RATIO
FROM
    (SELECT *,DIV0(PAYMENT_AMOUNT,MINIMUM_PAYMENT_DUE) AS MIN_PAY_RATIO
    FROM BASE
    WHERE BUSINESS_ID IN (SELECT * FROM Filter)
    AND PAYMENT_AMOUNT < STATEMENT_BALANCE
    )
WHERE TO_CHAR(STATEMENT_DATE,'YYYY-MM') < TO_CHAR(CURRENT_DATE,'YYYY-MM')
GROUP BY 1,2
UNION ALL
SELECT DATE_TRUNC('MONTH',STATEMENT_DATE) AS STATEMENT_MONTH, CC_FICO_BIN, AVG(MIN_PAY_RATIO)
FROM
    (SELECT *,DIV0(PAYMENT_AMOUNT,MINIMUM_PAYMENT_DUE) AS MIN_PAY_RATIO
    FROM BASE
    WHERE BUSINESS_ID IN (SELECT * FROM Filter)
    AND PAYMENT_AMOUNT < STATEMENT_BALANCE
    )
WHERE TO_CHAR(STATEMENT_DATE,'YYYY-MM') < TO_CHAR(CURRENT_DATE,'YYYY-MM')
GROUP BY 1,2
ORDER BY STATEMENT_MONTH, CC_FICO_BIN ASC;


--dda balance vs min pay
-- with most_recent_invite as (
-- select 
--  *
-- ,row_number() over (partition by business_id order by created_at desc) as rn
-- from fivetran_db.prod_novo_api_public.credit_card_invitations
-- ),
-- cc_statement as (
-- select
--  a.business_id
-- ,case
--  when b.fico_score between 581 and 619 then '580-620'
--  when b.fico_score between 620 and 659 then '620-660'
--  when b.fico_score between 660 and 719 then '660-720'
--  when b.fico_score between 720 and 779 then '720-780'
--  when b.fico_score between 780 and 850 then '780-850'
--  end as cc_fico_bin
-- ,row_number() over (partition by a.business_id order by a.created_at asc) as booking_stmt_no
-- ,round(a.minimum_payment_due/100,2) as min_pay_due
-- ,a.payment_due_date
-- from fivetran_db.prod_novo_api_public.credit_card_statements a
-- left join (select * from most_recent_invite where rn = 1) b
-- on a.business_id = b.business_id
-- where to_char(a.payment_due_date,'YYYY-MM') < to_char(current_date,'YYYY-MM')
-- and a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
-- ),
-- dda_balance as (
-- select
--  a.business_id
-- ,a.booking_stmt_no
-- ,avg(b.day_end_balance) as adb
-- ,max(b.day_end_balance) as max_balance
-- ,sum(case when b.date = payment_due_date - 1 then b.day_end_balance end) as day_before_balance
-- from cc_statement a
-- left join PROD_DB.DATA.BALANCES_DAILY b
-- on a.business_id = b.business_id
-- and b.date between dateadd(month,-1,a.payment_due_date - 1) and payment_due_date -1
-- group by 1,2
-- ),
-- final as (
-- select
--  a.*
-- ,b.adb
-- ,b.max_balance
-- ,b.day_before_balance
-- from cc_statement a
-- left join dda_balance b
-- on a.business_id = b.business_id
-- and a.booking_stmt_no = b.booking_stmt_no
-- where min_pay_due > 0
-- )
-- select
--  booking_stmt_no
-- ,cc_fico_bin
-- ,count(distinct business_id) as total_acct
-- ,count(case when adb >= min_pay_due then business_id end) as adb_enough_balance_acct
-- ,count(case when max_balance >= min_pay_due then business_id end) as max_enough_balance_acct
-- ,count(case when day_before_balance >= min_pay_due then business_id end) as daybefore_enough_balance_acct
-- from final
-- group by 1,2
-- union all
-- select
--  booking_stmt_no
-- ,'aggregate' as cc_fico_bin
-- ,count(distinct business_id) as total_acct
-- ,count(case when adb >= min_pay_due then business_id end) as adb_enough_balance_acct
-- ,count(case when max_balance >= min_pay_due then business_id end) as max_enough_balance_acct
-- ,count(case when day_before_balance >= min_pay_due then business_id end) as daybefore_enough_balance_acct
-- from final
-- group by 1,2
-- order by 1,2
-- ;


--nibt by report month
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
co_account as (
select
 distinct account_id
from (select * from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY)
where days_past_due = 181
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
,case
 when d.account_id is not null then 1
 else 0
 end as co_flag
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
left join co_account d
on a.account_id = d.account_id
where 1=1
and b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
interchange as (
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(a.interchange_gross_amount*-1/100),2) as interchange_amount
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS a
left join (select distinct business_id, fico_score, cc_account_id from loan_tape_updated where rn = 1) b
on a.credit_card_account_id = b.cc_account_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
),
interest_and_fees as (
select
 to_char(statement_date,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(case when co_flag = 1 then 0 else payment_allocated_interest end/100),2) as interest_collected
,round(sum(case when co_flag = 1 then 0 else payment_allocated_fees end/100),2) as fees_collected
,round(sum(case when co_flag = 1 then 0 else payment_allocated_principal end/100),2) as principal_collected
,count(distinct business_id) as open_vol
from (select * from loan_tape_updated where rn = 1)
group by 1,2
),
reward_accrued as (
select
 to_char(a.created_at,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin 
,coalesce(round(sum(rewards*-1/100),2),0) as reward_accrued
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS a
left join (select distinct business_id, fico_score, cc_account_id from loan_tape_updated where rn = 1) b
on a.credit_card_account_id = b.cc_account_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
group by 1,2
),
chargeoff as (
select
 to_char(statement_date,'YYYY-MM') as report_mth
,case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1/100 end),2) as chargeoff_total
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
group by 1,2
)
select
 a.report_mth
,a.cc_fico_bin
,b.interchange_amount
,a.interest_collected
,a.fees_collected
-- ,a.principal_collected
,c.reward_accrued
,d.chargeoff_total
,a.open_vol
from interest_and_fees a
left join interchange b
on a.report_mth = b.report_mth
and a.cc_fico_bin = b.cc_fico_bin
left join reward_accrued c
on a.report_mth = c.report_mth
and a.cc_fico_bin = c.cc_fico_bin
left join chargeoff d
on a.report_mth = d.report_mth
and a.cc_fico_bin = d.cc_fico_bin
where a.report_mth < to_char(current_date,'YYYY-MM')
and a.report_mth > '2024-11'
order by 1,2
;


--payment
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
co_account as (
select
 distinct account_id
from (select * from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY)
where days_past_due = 181
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
,case
 when d.account_id is not null then 1
 else 0
 end as co_flag
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
left join co_account d
on a.account_id = d.account_id
where 1=1
and b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
)
,starting_principal_balance as (
select
 to_char(statement_date,'YYYY-MM') as report_mth
,round(sum(ending_balance/100),2) as ending_balance_vf
,lag(ending_balance_vf) over (order by report_mth) as starting_balance
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select distinct last_day(statement_date) from loan_tape_updated)
group by 1
order by 1
)
,final as (
select
 to_char(statement_date,'YYYY-MM') as report_mth
,round(sum(case when co_flag = 1 then 0 else payment_allocated_principal end/100),2) as principal_payment
from (select * from loan_tape_updated where rn = 1)
group by 1
order by 1
)
select
 a.report_mth
,a.principal_payment
,b.ending_balance_vf
,b.starting_balance
from final a
left join starting_principal_balance b
on a.report_mth = b.report_mth
where a.report_mth >= '2024-12'
and a.report_mth < to_char(current_date,'YYYY-MM')
order by 1
;


--roll rate
--unit roll rate
with loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
)
,rollrate_data as (
select
 statement_date
,count(case when days_past_due = 0 then business_id end) as bucket_0_acct_vol
,count(case when days_past_due between 1 and 29 then business_id end) as bucket_1_acct_vol
,count(case when days_past_due between 30 and 59 then business_id end) as bucket_2_acct_vol
,count(case when days_past_due between 60 and 89 then business_id end) as bucket_3_acct_vol
,count(case when days_past_due between 90 and 119 then business_id end) as bucket_4_acct_vol
,count(case when days_past_due between 120 and 149 then business_id end) as bucket_5_acct_vol
,count(case when days_past_due between 150 and 179 then business_id end) as bucket_6_acct_vol
,count(case when days_past_due between 180 and 210 then business_id end) as bucket_7_acct_vol
,lead(bucket_0_acct_vol) over (order by statement_date desc) as prev_bucket_0_acct_vol
,lead(bucket_1_acct_vol) over (order by statement_date desc) as prev_bucket_1_acct_vol
,lead(bucket_2_acct_vol) over (order by statement_date desc) as prev_bucket_2_acct_vol
,lead(bucket_3_acct_vol) over (order by statement_date desc) as prev_bucket_3_acct_vol
,lead(bucket_4_acct_vol) over (order by statement_date desc) as prev_bucket_4_acct_vol
,lead(bucket_5_acct_vol) over (order by statement_date desc) as prev_bucket_5_acct_vol
,lead(bucket_6_acct_vol) over (order by statement_date desc) as prev_bucket_6_acct_vol
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated)
group by 1
order by 1
)
select
 statement_date
,bucket_1_acct_vol/nullifzero(prev_bucket_0_acct_vol) as rollrate_0_to_1
,bucket_2_acct_vol/nullifzero(prev_bucket_1_acct_vol) as rollrate_1_to_2
,bucket_3_acct_vol/nullifzero(prev_bucket_2_acct_vol) as rollrate_2_to_3
,bucket_4_acct_vol/nullifzero(prev_bucket_3_acct_vol) as rollrate_3_to_4
,bucket_5_acct_vol/nullifzero(prev_bucket_4_acct_vol) as rollrate_4_to_5
,bucket_6_acct_vol/nullifzero(prev_bucket_5_acct_vol) as rollrate_5_to_6
,bucket_7_acct_vol/nullifzero(prev_bucket_6_acct_vol) as rollrate_6_to_7
from rollrate_data
;


--dollar roll rate
with loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
)
,rollrate_data as (
select
 statement_date
,sum(case when days_past_due = 0 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_0_dollar_amount
,sum(case when days_past_due between 1 and 29 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_1_dollar_amount
,sum(case when days_past_due between 30 and 59 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_2_dollar_amount
,sum(case when days_past_due between 60 and 89 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_3_dollar_amount
,sum(case when days_past_due between 90 and 119 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_4_dollar_amount
,sum(case when days_past_due between 120 and 149 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_5_dollar_amount
,sum(case when days_past_due between 150 and 179 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_6_dollar_amount
,sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) as bucket_7_dollar_amount
,lead(bucket_0_dollar_amount) over (order by statement_date desc) as prev_bucket_0_dollar_amount
,lead(bucket_1_dollar_amount) over (order by statement_date desc) as prev_bucket_1_dollar_amount
,lead(bucket_2_dollar_amount) over (order by statement_date desc) as prev_bucket_2_dollar_amount
,lead(bucket_3_dollar_amount) over (order by statement_date desc) as prev_bucket_3_dollar_amount
,lead(bucket_4_dollar_amount) over (order by statement_date desc) as prev_bucket_4_dollar_amount
,lead(bucket_5_dollar_amount) over (order by statement_date desc) as prev_bucket_5_dollar_amount
,lead(bucket_6_dollar_amount) over (order by statement_date desc) as prev_bucket_6_dollar_amount
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated)
group by 1
order by 1
)
select
 statement_date
,bucket_1_dollar_amount/nullifzero(prev_bucket_0_dollar_amount) as rollrate_0_to_1
,bucket_2_dollar_amount/nullifzero(prev_bucket_1_dollar_amount) as rollrate_1_to_2
,bucket_3_dollar_amount/nullifzero(prev_bucket_2_dollar_amount) as rollrate_2_to_3
,bucket_4_dollar_amount/nullifzero(prev_bucket_3_dollar_amount) as rollrate_3_to_4
,bucket_5_dollar_amount/nullifzero(prev_bucket_4_dollar_amount) as rollrate_4_to_5
,bucket_6_dollar_amount/nullifzero(prev_bucket_5_dollar_amount) as rollrate_5_to_6
,bucket_7_dollar_amount/nullifzero(prev_bucket_6_dollar_amount) as rollrate_6_to_7
from rollrate_data
;


--c-30/60/90/120
with loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
)
,rollrate_data as (
select
 statement_date
,sum(case when days_past_due = 0 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_0_dollar_amount
,sum(case when days_past_due between 1 and 29 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_1_dollar_amount
,sum(case when days_past_due between 30 and 59 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_2_dollar_amount
,sum(case when days_past_due between 60 and 89 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_3_dollar_amount
,sum(case when days_past_due between 90 and 119 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_4_dollar_amount
,sum(case when days_past_due between 120 and 149 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_5_dollar_amount
,sum(case when days_past_due between 150 and 179 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_6_dollar_amount
,sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as bucket_7_dollar_amount
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated)
group by 1
order by 1
)
select
 statement_date
,bucket_0_dollar_amount
,bucket_1_dollar_amount
,bucket_2_dollar_amount
,bucket_3_dollar_amount
,bucket_4_dollar_amount
,bucket_5_dollar_amount
,bucket_6_dollar_amount
,bucket_7_dollar_amount
from rollrate_data
where to_char(statement_date,'YYYY-MM') > '2024-11'
;



----booking vintage breakdown----
--active (balance > $0)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,case
 when (b.purchases > 0  or b.statement_balance > 0) then 1
 else 0 end as active_flag
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due <= 210 and a.active_flag = 1 then a.business_id end) as active_vol,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due <= 210 and a.active_flag = 1 then a.business_id end) as active_vol,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 active_vol,
 open_vol
from final
where booking_month != '2025-09'
order by 1,2,3
;


--os
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 round(sum(case when a.days_past_due <= 210 then a.daily_balance_purchases end/100),2) as adb,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 round(sum(case when a.days_past_due <= 210 then a.daily_balance_purchases end/100),2) as adb,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 adb,
 open_vol
from final
where booking_month != '2025-09'
order by 1,2,3
;


--pvol
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
,b.purchases
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 round(sum(purchases/100),2) as pvol,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 count(case when purchases> 0 and a.days_past_due <= 210 then a.business_id end) as active_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 round(sum(purchases/100),2) as pvol,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 count(case when purchases> 0 and a.days_past_due <= 210 then a.business_id end) as active_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 pvol,
 open_vol,
 active_vol
from final
where booking_month != '2025-09'
order by 1,2,3
;


--utilization
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when a.billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end)/sum(case when a.days_past_due <= 210 then a.credit_limit end),3) as util_rate,
 round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb,
 round(sum(case when a.days_past_due <= 210 then a.credit_limit end/100),2) as cl_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when a.billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end)/sum(case when a.days_past_due <= 210 then a.credit_limit end),3) as util_rate,
 round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb,
 round(sum(case when a.days_past_due <= 210 then a.credit_limit end/100),2) as cl_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 util_rate,
 adb,
 cl_total,
 open_vol
from final
order by 1,2,3
;


--rev rate
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 round(sum(case when a.grace_period = 'false' and booking_stmt_no >= 1 and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end)/sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)),3) as rev_rate,
  round(sum(case when a.grace_period = 'false' and booking_stmt_no >= 1 and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as stfc,
  round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb,
 count(distinct a.business_id) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 round(sum(case when a.grace_period = 'false' and booking_stmt_no >= 1 and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)end)/sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)),3) as rev_rate,
  round(sum(case when a.grace_period = 'false' and booking_stmt_no >= 1 and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as stfc,
  round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb,
 count(distinct a.business_id) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 case when booking_stmt_no = 1 then 0 else rev_rate end as rev_rate_vf,
 case when booking_stmt_no = 1 then 0 else stfc end as stfc,
 adb,
 open_vol
from final
order by 1,2,3
;


---dq1-29 unit & dollar
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 1 and 29 then a.business_id end) as dq1to29_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 1 and 29 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq1to29_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((case when a.days_past_due <= 210 then next_due_principal+past_statements_principal+due_principal+past_due_principal end)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 1 and 29 then a.business_id end) as dq1to29_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 1 and 29 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq1to29_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 dq1to29_unit_count,
 open_vol,
 dq1to29_dollar_amount,
 outstanding_balance,
 principal_balance
from final
order by 1,2,3
;


---dq30-59 unit & dollar
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 30 and 59 then a.business_id end) as dq30to59_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 30 and 59 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq30to59_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((case when a.days_past_due <= 210 then next_due_principal+past_statements_principal+due_principal+past_due_principal end)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 30 and 59 then a.business_id end) as dq30to59_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 30 and 59 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq30to59_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 dq30to59_unit_count,
 open_vol,
 dq30to59_dollar_amount,
 outstanding_balance,
 principal_balance
from final
order by 1,2,3
;



---dq30+ unit & dollar
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 30 and 210 then a.business_id end) as dq30plus_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 30 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq30plus_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((case when a.days_past_due <= 210 then next_due_principal+past_statements_principal+due_principal+past_due_principal end)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 30 and 210 then a.business_id end) as dq30plus_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 30 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq30plus_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 dq30plus_unit_count,
 open_vol,
 dq30plus_dollar_amount,
 outstanding_balance,
 principal_balance
from final
order by 1,2,3
;


---dq60+ unit & dollar
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 60 and 210 then a.business_id end) as dq60plus_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 60 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq60plus_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((case when a.days_past_due <= 210 then next_due_principal+past_statements_principal+due_principal+past_due_principal end)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 60 and 210 then a.business_id end) as dq60plus_unit_count,
 count(case when a.days_past_due <= 210 then business_id end) as open_vol,
 sum(case when a.days_past_due between 60 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as dq60plus_dollar_amount,
 sum(case when a.days_past_due <= 210 then a.ending_balance end/100) as outstanding_balance,
 sum((case when a.days_past_due <= 210 then next_due_principal+past_statements_principal+due_principal+past_due_principal end)/100) as principal_balance
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 dq60plus_unit_count,
 open_vol,
 dq60plus_dollar_amount,
 outstanding_balance,
 principal_balance
from final
order by 1,2,3
;



--cum co unit
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.created_at
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
),
loan_tape_statement_join as (
select
 a.*
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(dateadd(day,-1,b.created_at),'YYYY-MM-DD')
where 1=1
order by business_id
),
per_orig as 
(
select
 to_char(created_at,'YYYY-MM') as booking_month
,CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month
,'aggregate' AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 sum(case when a.days_past_due between 180 and 210 then a.ending_balance/100 end) as co_dollar_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 sum(case when a.days_past_due between 180 and 210 then a.ending_balance/100 end) as co_dollar_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,sum(a.co_unit_vol) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no) as cum_co_unit_vol
,b.acct_vol_orig
,a.co_unit_vol
,a.open_vol
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;


--cum co dollar
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.created_at
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
),
loan_tape_statement_join as (
select
 a.*
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(dateadd(day,-1,b.created_at),'YYYY-MM-DD')
where 1=1
order by business_id
),
per_orig as 
(
select
 to_char(created_at,'YYYY-MM') as booking_month
,CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month
,'aggregate' AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 coalesce(sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100 ),0) as co_dollar_total,
 sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100) as principal_outstanding,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 coalesce(sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100 ),0) as co_dollar_total,
 sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100) as principal_outstanding,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,sum(a.co_unit_vol) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no) as cum_co_unit_vol
,sum(a.co_dollar_total) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no) as cum_co_dollar_total
,a.co_dollar_total
,a.principal_outstanding
,b.acct_vol_orig
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;


--severity
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 round(sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as co_amount,
 round(sum(case when a.days_past_due between 180 and 210 then a.credit_limit/100 end)) as cl_total,
 count(case when days_past_due <= 210 then business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 round(sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as co_amount,
 round(sum(case when a.days_past_due between 180 and 210 then a.credit_limit/100 end)) as cl_total,
 count(case when days_past_due <= 210 then business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month,
 booking_stmt_no,
 cc_fico_bin,
 coalesce(co_amount,0) as co_amount,
 coalesce(cl_total,0) as cl_total,
 open_vol
from final
order by 1,2,3
;



--min pay ratio
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1
),
loan_tape_statement_join1 as (
select
 a.*
,c.created_at
,b.minimum_payment_due
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
loan_tape_statement_join2 as (
select
 a.business_id
,to_char(dateadd(day,1,a.statement_date::date),'YYYY-MM-DD') as statement_date
,a.period_payments
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(dateadd(day,-1,b.created_at::date),'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
loan_tape_statement_join_vf as (
select
 a.*
,b.period_payments as period_payments_vf
from loan_tape_statement_join1 a
left join loan_tape_statement_join2 b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when a.billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then a.period_payments_vf*-1 end) as total_payment,
 sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then a.minimum_payment_due end) as min_pay_due,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join_vf a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when a.billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then a.period_payments_vf*-1 end) as total_payment,
 sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then a.minimum_payment_due end) as min_pay_due,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join_vf a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 booking_month
,booking_stmt_no
,cc_fico_bin
,total_payment
,min_pay_due
,open_vol
from final
order by 1,2,3
;


--cum nibt
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,fico_score
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1,2
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
,b.start_date
,b.end_date
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
interchange as (
select
 a.business_id
,a.statement_date
,round(sum(b.interchange_gross_amount*-1/100),2) as interchange_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
interest_and_fees as (
select
 a.business_id
,a.statement_date
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_interest end/100),2) as interest_collected
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_fees end/100),2) as fees_collected
from loan_tape_statement_join a
left join (select * from loan_tape_updated where rn = 1) b
on a.business_id = b.business_id
and b.statement_date between dateadd(day,1,start_date) and dateadd(day,1,end_date)
group by 1,2
),
reward_redemption as (
select
 a.business_id
,a.statement_date
,coalesce(round(sum(rewards*-1/100),2),0) as reward_accrued
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
per_orig as (
select
 to_char(created_at,'YYYY-MM') as booking_month,
 'aggregate' AS CC_FICO_BIN,
 count(business_id) as acct_vol_orig
from booking_date
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month,
 CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from booking_date
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 coalesce(sum(c.interest_collected),0) as interest_collected,
 coalesce(sum(c.fees_collected),0) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = dateadd(month,1,c.statement_date)
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 coalesce(sum(c.interest_collected),0) as interest_collected,
 coalesce(sum(c.fees_collected),0) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = dateadd(month,1,c.statement_date)
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,sum(a.interchange_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_ich
,sum(a.interest_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_int_collected
,sum(a.fees_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fees_collected
,sum(a.reward_accrued) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_reward_accrued
,sum(a.co_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_co_amount
,a.open_vol
,b.acct_vol_orig
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;



--nibt (non-cum)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,fico_score
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1,2
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
,b.start_date
,b.end_date
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
interchange as (
select
 a.business_id
,a.statement_date
,round(sum(b.interchange_gross_amount*-1/100),2) as interchange_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
interest_and_fees as (
select
 a.business_id
,a.statement_date
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_interest end/100),2) as interest_collected
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_fees end/100),2) as fees_collected
from loan_tape_statement_join a
left join (select * from loan_tape_updated where rn = 1) b
on a.business_id = b.business_id
and b.statement_date between dateadd(day,1,start_date) and dateadd(day,1,end_date)
group by 1,2
),
reward_redemption as (
select
 a.business_id
,a.statement_date
,coalesce(round(sum(rewards*-1/100),2),0) as reward_accrued
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
per_orig as (
select
 to_char(created_at,'YYYY-MM') as booking_month,
 'aggregate' AS CC_FICO_BIN,
 count(business_id) as acct_vol_orig
from booking_date
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month,
 CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from booking_date
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 coalesce(sum(c.interest_collected),0) as interest_collected,
 coalesce(sum(c.fees_collected),0) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = dateadd(month,1,c.statement_date)
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 coalesce(sum(c.interest_collected),0) as interest_collected,
 coalesce(sum(c.fees_collected),0) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = dateadd(month,1,c.statement_date)
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,a.interchange_amount
,a.interest_collected
,a.fees_collected
,a.reward_accrued
,a.co_amount
,a.open_vol
,b.acct_vol_orig
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;


--co unit (non-cum)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.created_at
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
),
loan_tape_statement_join as (
select
 a.*
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(dateadd(day,-1,b.created_at),'YYYY-MM-DD')
where 1=1
order by business_id
),
per_orig as 
(
select
 to_char(created_at,'YYYY-MM') as booking_month
,CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month
,'aggregate' AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from loan_tape_statement_join
where billing_period_number = 1
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as co_dollar_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 a.billing_period_number as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 count(case when a.days_past_due between 180 and 210 then a.business_id end) as co_unit_vol,
 sum(case when a.days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end) as co_dollar_total,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,a.co_unit_vol
,b.acct_vol_orig
,a.co_dollar_total
,a.open_vol
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;


--cum nibt (dpd60+ as co proxy)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,fico_score
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1,2
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
,b.start_date
,b.end_date
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
interchange as (
select
 a.business_id
,a.statement_date
,round(sum(b.interchange_gross_amount*-1/100),2) as interchange_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
purchase_fraud as (
select
 a.business_id
,a.statement_date
,round(sum(b.amount*-1/100),2) as purchase_fraud_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_DISPUTES b
on a.business_id = b.business_id
and to_char(a.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
where b.status = 'accepted'
group by 1,2
),
interest_and_fees as (
select
 a.business_id
,a.statement_date
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_interest end/100),2) as interest_collected
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_fees end/100),2) as fees_collected
from loan_tape_statement_join a
left join (select * from loan_tape_updated where rn = 1) b
on a.business_id = b.business_id
and b.statement_date between b.start_date and b.end_date
group by 1,2
),
reward_redemption as (
select
 a.business_id
,a.statement_date
,coalesce(round(sum(rewards*-1/100),2),0) as reward_accrued
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
per_orig as (
select
 to_char(created_at,'YYYY-MM') as booking_month,
 'aggregate' AS CC_FICO_BIN,
 count(business_id) as acct_vol_orig
from booking_date
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month,
 CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from booking_date
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 sum(c.interest_collected) as interest_collected,
 sum(c.fees_collected) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 round(sum(case when days_past_due between 60 and 89 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 sum(e.purchase_fraud_amount) as purchase_fraud_amount,
 round(sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100),2) as principal_balance_outstanding
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = c.statement_date
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
left join purchase_fraud e
on a.business_id = e.business_id
and a.statement_date = e.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 sum(c.interest_collected) as interest_collected,
 sum(c.fees_collected) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 round(sum(case when days_past_due between 60 and 89 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 sum(e.purchase_fraud_amount) as purchase_fraud_amount,
 round(sum((next_due_principal+past_statements_principal+due_principal+past_due_principal)/100),2) as principal_balance_outstanding
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = c.statement_date
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
left join purchase_fraud e
on a.business_id = e.business_id
and a.statement_date = e.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,sum(a.interchange_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_ich
,sum(a.interest_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_int_collected
,sum(a.fees_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fees_collected
,sum(a.reward_accrued) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_reward_accrued
,sum(a.co_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_co_amount
,a.open_vol
,b.acct_vol_orig
,sum(a.purchase_fraud_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fraud_amount
,a.principal_balance_outstanding
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;


--cum nibt (actual CO)
with most_recent_invite as (
select
 *
,row_number() over (partition by business_id order by created_at desc) as rn
from fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated as (
select
 a.*
,b.business_id
,b.id as cc_account_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
,c.fico_score
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
left join (select * from most_recent_invite where rn = 1) c
on b.business_id = c.business_id
where b.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number >= 1
),
booking_date as (
select
 business_id
,fico_score
,min(statement_date) as created_at
from (select * from loan_tape_updated where rn = 1)
group by 1,2
),
loan_tape_statement_join as (
select
 a.*
,c.created_at
,b.start_date
,b.end_date
from (select * from loan_tape_updated where rn = 1) a
right join (select * from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS where business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')) b
on a.business_id = b.business_id
and to_char(a.statement_date,'YYYY-MM-DD') = to_char(b.created_at,'YYYY-MM-DD')
left join booking_date c
on a.business_id = c.business_id
),
interchange as (
select
 a.business_id
,a.statement_date
,round(sum(b.interchange_gross_amount*-1/100),2) as interchange_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
purchase_fraud as (
select
 a.business_id
,a.statement_date
,round(sum(b.amount*-1/100),2) as purchase_fraud_amount
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_DISPUTES b
on a.business_id = b.business_id
and to_char(a.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
where b.status = 'accepted'
group by 1,2
),
interest_and_fees as (
select
 a.business_id
,a.statement_date
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_interest end/100),2) as interest_collected
,round(sum(case when a.days_past_due >= 181 then 0 else b.payment_allocated_fees end/100),2) as fees_collected
from loan_tape_statement_join a
left join (select * from loan_tape_updated where rn = 1) b
on a.business_id = b.business_id
and b.statement_date between dateadd(day,1,start_date) and dateadd(day,1,end_date)
group by 1,2
),
reward_redemption as (
select
 a.business_id
,a.statement_date
,coalesce(round(sum(rewards*-1/100),2),0) as reward_accrued
from loan_tape_statement_join a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS b
on a.cc_account_id = b.credit_card_account_id
and to_char(b.created_at,'YYYY-MM-DD') between a.start_date and a.end_date
group by 1,2
),
per_orig as (
select
 to_char(created_at,'YYYY-MM') as booking_month,
 'aggregate' AS CC_FICO_BIN,
 count(business_id) as acct_vol_orig
from booking_date
group by 1,2
union all
select
 to_char(created_at,'YYYY-MM') as booking_month,
 CASE
 WHEN FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN
,count(business_id) as acct_vol_orig
from booking_date
group by 1,2
),
final as (
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 'aggregate' AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 sum(c.interest_collected) as interest_collected,
 sum(c.fees_collected) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 sum(e.purchase_fraud_amount) as purchase_fraud_amount
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = c.statement_date
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
left join purchase_fraud e
on a.business_id = e.business_id
and a.statement_date = e.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
union all
select
 to_char(a.created_at,'YYYY-MM') as booking_month,
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no,
 CASE
 WHEN a.FICO_SCORE BETWEEN 581 and 619 THEN '580-620'
 WHEN a.FICO_SCORE BETWEEN 620 and 659 THEN '620-660'
 WHEN a.FICO_SCORE BETWEEN 660 and 719 THEN '660-720'
 WHEN a.FICO_SCORE BETWEEN 720 AND 779 THEN '720-780'
 WHEN a.FICO_SCORE BETWEEN 780 and 850 THEN '780-850'
 END AS CC_FICO_BIN,
 sum(b.interchange_amount) as interchange_amount,
 sum(c.interest_collected) as interest_collected,
 sum(c.fees_collected) as fees_collected,
 sum(d.reward_accrued) as reward_accrued,
 round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2) as co_amount,
 count(case when a.days_past_due <= 210 then a.business_id end) as open_vol,
 sum(e.purchase_fraud_amount) as purchase_fraud_amount
from loan_tape_statement_join a
left join interchange b
on a.business_id = b.business_id
and a.statement_date = b.statement_date
left join interest_and_fees c
on a.business_id = c.business_id
and a.statement_date = c.statement_date
left join reward_redemption d
on a.business_id = d.business_id
and a.statement_date = d.statement_date
left join purchase_fraud e
on a.business_id = e.business_id
and a.statement_date = e.statement_date
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and booking_month < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
group by 1,2,3
)
select
 a.booking_month
,a.booking_stmt_no
,a.cc_fico_bin
,sum(a.interchange_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_ich
,sum(a.interest_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_int_collected
,sum(a.fees_collected) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fees_collected
,sum(a.reward_accrued) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_reward_accrued
,sum(a.co_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_co_amount
,a.open_vol
,b.acct_vol_orig
,sum(a.purchase_fraud_amount) over (partition by a.booking_month, a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fraud_amount
from final a
left join per_orig b
on a.booking_month = b.booking_month
and a.cc_fico_bin = b.cc_fico_bin
order by 1,2,3
;