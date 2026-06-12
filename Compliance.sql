-- ============================================================
-- Application IDs: Apr 2026 – May 27 2026
-- ============================================================
select
     a.id                                                                         as application_id
    ,a.business_id
    ,a.status
    ,to_char(a.created_at, 'YYYY-MM-DD')                                          as applied_at
    ,case when a.status = 'APPROVED' then to_char(a.created_at, 'YYYY-MM-DD') end as booking_date
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
where a.created_at >= '2026-04-01'
  and a.created_at <  '2026-05-28'
  and a.business_id not in (
      select business_id
      from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
order by a.created_at
;
