---------------------------CC------------------------------
------CREDIT CARD - VINTAGE SNAPSHOT-----------
-- DQ30+ rate at statement 3 (accounts with >= 3 months of booking)
-- DQ30-59 rate at statement 6 (accounts with >= 6 months of booking)
-- NIBT at statement 6 (accounts with >= 6 months of booking)
-- Revolve rate at statement 6 (accounts with >= 6 months of booking)


--dq30+ rate at statement 3
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
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,'aggregate' as cc_fico_bin
,count(case when a.days_past_due between 30 and 210 then a.business_id end) as dq30plus_unit_count
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 3
group by 1,2
union all
select
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,case
 when a.fico_score between 581 and 619 then '580-620'
 when a.fico_score between 620 and 659 then '620-660'
 when a.fico_score between 660 and 719 then '660-720'
 when a.fico_score between 720 and 779 then '720-780'
 when a.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,count(case when a.days_past_due between 30 and 210 then a.business_id end) as dq30plus_unit_count
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 3
group by 1,2
)
select
 cc_fico_bin
,dq30plus_unit_count
,open_vol
,round(dq30plus_unit_count / nullifzero(open_vol),4) as dq30plus_rate
,os_total
,total_cl
,round(os_total / nullifzero(total_cl),4) as util_rate
from final
where booking_stmt_no = 3
order by 1
;


--dq30-59 rate at statement 6
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
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,'aggregate' as cc_fico_bin
,count(case when a.days_past_due between 30 and 59 then a.business_id end) as dq30to59_unit_count
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
union all
select
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,case
 when a.fico_score between 581 and 619 then '580-620'
 when a.fico_score between 620 and 659 then '620-660'
 when a.fico_score between 660 and 719 then '660-720'
 when a.fico_score between 720 and 779 then '720-780'
 when a.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,count(case when a.days_past_due between 30 and 59 then a.business_id end) as dq30to59_unit_count
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
)
select
 cc_fico_bin
,dq30to59_unit_count
,open_vol
,round(dq30to59_unit_count / nullifzero(open_vol),4) as dq30to59_rate
,os_total
,total_cl
,round(os_total / nullifzero(total_cl),4) as util_rate
from final
where booking_stmt_no = 6
order by 1
;


--nibt at statement 6
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
 'aggregate' as cc_fico_bin
,count(business_id) as acct_vol_orig
from booking_date
where datediff(month,created_at,current_date) >= 6
group by 1
union all
select
 case
 when fico_score between 581 and 619 then '580-620'
 when fico_score between 620 and 659 then '620-660'
 when fico_score between 660 and 719 then '660-720'
 when fico_score between 720 and 779 then '720-780'
 when fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,count(business_id) as acct_vol_orig
from booking_date
where datediff(month,created_at,current_date) >= 6
group by 1
),
final as (
select
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,'aggregate' as cc_fico_bin
,sum(b.interchange_amount) as interchange_amount
,coalesce(sum(c.interest_collected),0) as interest_collected
,coalesce(sum(c.fees_collected),0) as fees_collected
,sum(d.reward_accrued) as reward_accrued
,coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
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
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
union all
select
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,case
 when a.fico_score between 581 and 619 then '580-620'
 when a.fico_score between 620 and 659 then '620-660'
 when a.fico_score between 660 and 719 then '660-720'
 when a.fico_score between 720 and 779 then '720-780'
 when a.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,sum(b.interchange_amount) as interchange_amount
,coalesce(sum(c.interest_collected),0) as interest_collected
,coalesce(sum(c.fees_collected),0) as fees_collected
,sum(d.reward_accrued) as reward_accrued
,coalesce(round(sum(case when days_past_due between 180 and 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)*-1 end)/100,2),0) as co_amount
,count(case when a.days_past_due <= 210 then a.business_id end) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
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
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
)
select
 cc_fico_bin
,cum_interchange
,cum_interest_collected
,cum_fees_collected
,cum_reward_accrued
,cum_co_amount
,coalesce(cum_interchange,0) + cum_interest_collected + cum_fees_collected + coalesce(cum_reward_accrued,0) + coalesce(cum_co_amount,0) as cum_nibt
,open_vol
,acct_vol_orig
,os_total
,total_cl
,util_rate
from (
select
 a.cc_fico_bin
,a.booking_stmt_no
,sum(a.interchange_amount) over (partition by a.cc_fico_bin order by a.booking_stmt_no asc) as cum_interchange
,sum(a.interest_collected) over (partition by a.cc_fico_bin order by a.booking_stmt_no asc) as cum_interest_collected
,sum(a.fees_collected) over (partition by a.cc_fico_bin order by a.booking_stmt_no asc) as cum_fees_collected
,sum(a.reward_accrued) over (partition by a.cc_fico_bin order by a.booking_stmt_no asc) as cum_reward_accrued
,sum(a.co_amount) over (partition by a.cc_fico_bin order by a.booking_stmt_no asc) as cum_co_amount
,a.open_vol
,b.acct_vol_orig
,a.os_total
,a.total_cl
,round(a.os_total / nullifzero(a.total_cl),4) as util_rate
from final a
left join per_orig b
on a.cc_fico_bin = b.cc_fico_bin
)
where booking_stmt_no = 6
order by 1
;


--revolve rate at statement 6
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
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,'aggregate' as cc_fico_bin
,round(sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) / nullifzero(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end)),3) as rev_rate
,round(sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as stfc
,round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb
,count(distinct a.business_id) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
union all
select
 case when billing_period_number-1 = 0 then billing_period_number else billing_period_number-1 end as booking_stmt_no
,case
 when a.fico_score between 581 and 619 then '580-620'
 when a.fico_score between 620 and 659 then '620-660'
 when a.fico_score between 660 and 719 then '660-720'
 when a.fico_score between 720 and 779 then '720-780'
 when a.fico_score between 780 and 850 then '780-850'
 end as cc_fico_bin
,round(sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end) / nullifzero(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end)),3) as rev_rate
,round(sum(case when a.grace_period = 'false' and a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 end),2) as stfc
,round(sum(case when a.days_past_due <= 210 then (next_due_principal+past_statements_principal+due_principal+past_due_principal) end/100),2) as adb
,count(distinct a.business_id) as open_vol
,round(sum(case when a.days_past_due <= 210 then a.ending_balance/100 end),2) as os_total
,round(sum(case when a.days_past_due <= 210 then a.credit_limit/100 end),2) as total_cl
from loan_tape_statement_join a
where a.business_id not in (select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e')
and a.billing_period_number != 0
and to_char(a.created_at,'YYYY-MM') < to_char(dateadd(month,-1,current_date),'YYYY-MM')
and booking_stmt_no < datediff(month,a.created_at,current_date)
and datediff(month,a.created_at,current_date) >= 6
group by 1,2
)
select
 cc_fico_bin
,rev_rate
,stfc
,adb
,open_vol
,os_total
,total_cl
,round(os_total / nullifzero(total_cl),4) as util_rate
from final
where booking_stmt_no = 6
order by 1
;
