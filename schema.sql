-- قاعدة بيانات كشوف الحساب الأسبوعية - عز الدين للمقاولات
create table if not exists public.ezz_accounts (
  id bigint generated always as identity primary key,
  name text not null unique,
  type text not null check (type in ('سواق','محجر','عميل محجر','عميل شركة')),
  phone text,
  opening_balance numeric(14,2) not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.ezz_entries (
  id bigint generated always as identity primary key,
  entry_date date not null,
  account_id bigint not null references public.ezz_accounts(id) on delete restrict,
  vehicle text,
  trailer text,
  bon_no text,
  trips numeric(10,2),
  cubic numeric(10,2),
  deduction numeric(10,2) not null default 0,
  quantity numeric(14,2) generated always as (coalesce(trips,0)*coalesce(cubic,0) - coalesce(deduction,0)) stored,
  price numeric(12,2),
  value numeric(14,2) generated always as ((coalesce(trips,0)*coalesce(cubic,0) - coalesce(deduction,0)) * coalesce(price,0)) stored,
  payments numeric(14,2) not null default 0,
  net numeric(14,2) generated always as ((coalesce(trips,0)*coalesce(cubic,0) - coalesce(deduction,0)) * coalesce(price,0) - coalesce(payments,0)) stored,
  contractor text,
  company text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists ezz_entries_acc_date on public.ezz_entries(account_id, entry_date);

-- الرصيد المرحّل قبل تاريخ معين = الرصيد الافتتاحي + صافي كل الحركات قبل التاريخ
create or replace function public.ezz_balance_before(p_account bigint, p_date date)
returns numeric language sql stable security invoker set search_path = public as $$
  select coalesce((select opening_balance from ezz_accounts where id = p_account),0)
       + coalesce((select sum(net) from ezz_entries where account_id = p_account and entry_date < p_date),0);
$$;

-- ملخص أرصدة كل الحسابات لأسبوع
create or replace function public.ezz_week_summary(p_start date)
returns table(account_id bigint, name text, type text, prev_balance numeric, trips numeric,
              quantity numeric, value numeric, payments numeric, week_net numeric, balance numeric)
language sql stable security invoker set search_path = public as $$
  select a.id, a.name, a.type,
         a.opening_balance + coalesce(sum(e.net) filter (where e.entry_date < p_start),0),
         coalesce(sum(e.trips) filter (where e.entry_date between p_start and p_start+6),0),
         coalesce(sum(e.quantity) filter (where e.entry_date between p_start and p_start+6),0),
         coalesce(sum(e.value) filter (where e.entry_date between p_start and p_start+6),0),
         coalesce(sum(e.payments) filter (where e.entry_date between p_start and p_start+6),0),
         coalesce(sum(e.net) filter (where e.entry_date between p_start and p_start+6),0),
         a.opening_balance + coalesce(sum(e.net) filter (where e.entry_date <= p_start+6),0)
  from ezz_accounts a left join ezz_entries e on e.account_id = a.id
  group by a.id order by a.type, a.name;
$$;

-- المستخدمين المسموح لهم (بالإيميل)
create table if not exists public.ezz_members (
  email text primary key,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.ezz_is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from ezz_members where lower(email) = lower(auth.jwt()->>'email'));
$$;
create or replace function public.ezz_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from ezz_members where lower(email) = lower(auth.jwt()->>'email') and is_admin);
$$;
-- أول واحد يسجل بيبقى المدير، بعد كده المدير بس اللي يضيف ناس
create or replace function public.ezz_claim_first_admin()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists(select 1 from ezz_members) then return ezz_is_member(); end if;
  insert into ezz_members(email,is_admin) values (lower(auth.jwt()->>'email'), true);
  return true;
end $$;

alter table public.ezz_members enable row level security;
alter table public.ezz_accounts enable row level security;
alter table public.ezz_entries enable row level security;
drop policy if exists ezz_members_read on public.ezz_members;
create policy ezz_members_read on public.ezz_members for select to authenticated using (ezz_is_member());
drop policy if exists ezz_members_admin on public.ezz_members;
create policy ezz_members_admin on public.ezz_members for all to authenticated using (ezz_is_admin()) with check (ezz_is_admin());
drop policy if exists ezz_accounts_auth on public.ezz_accounts;
create policy ezz_accounts_auth on public.ezz_accounts for all to authenticated using (ezz_is_member()) with check (ezz_is_member());
drop policy if exists ezz_entries_auth on public.ezz_entries;
create policy ezz_entries_auth on public.ezz_entries for all to authenticated using (ezz_is_member()) with check (ezz_is_member());
revoke all on public.ezz_accounts, public.ezz_entries, public.ezz_members from anon;
revoke execute on function public.ezz_balance_before(bigint,date), public.ezz_week_summary(date), public.ezz_is_member(), public.ezz_is_admin(), public.ezz_claim_first_admin() from anon, public;
grant execute on function public.ezz_balance_before(bigint,date), public.ezz_week_summary(date), public.ezz_is_member(), public.ezz_is_admin(), public.ezz_claim_first_admin() to authenticated;
