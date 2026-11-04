-- قاعدة بيانات كشوف الحساب الأسبوعية - عز الدين للمقاولات
create table if not exists public.asem_accounts (
  id bigint generated always as identity primary key,
  name text not null unique,
  type text not null check (type in ('سواق','محجر','عميل محجر','عميل شركة')),
  phone text,
  opening_balance numeric(14,2) not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.asem_entries (
  id bigint generated always as identity primary key,
  entry_date date not null,
  account_id bigint not null references public.asem_accounts(id) on delete restrict,
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
create index if not exists asem_entries_acc_date on public.asem_entries(account_id, entry_date);

-- الرصيد المرحّل قبل تاريخ معين = الرصيد الافتتاحي + صافي كل الحركات قبل التاريخ
create or replace function public.asem_balance_before(p_account bigint, p_date date)
returns numeric language sql stable security invoker set search_path = public as $$
  select coalesce((select opening_balance from asem_accounts where id = p_account),0)
       + coalesce((select sum(net) from asem_entries where account_id = p_account and entry_date < p_date),0);
$$;

-- ملخص أرصدة كل الحسابات لأسبوع
create or replace function public.asem_week_summary(p_start date)
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
  from asem_accounts a left join asem_entries e on e.account_id = a.id
  group by a.id order by a.type, a.name;
$$;

-- المستخدمين المسموح لهم (بالإيميل)
create table if not exists public.asem_members (
  email text primary key,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.asem_is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from asem_members where lower(email) = lower(auth.jwt()->>'email'));
$$;
create or replace function public.asem_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from asem_members where lower(email) = lower(auth.jwt()->>'email') and is_admin);
$$;
-- أول واحد يسجل بيبقى المدير، بعد كده المدير بس اللي يضيف ناس
create or replace function public.asem_claim_first_admin()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists(select 1 from asem_members) then return asem_is_member(); end if;
  insert into asem_members(email,is_admin) values (lower(auth.jwt()->>'email'), true);
  return true;
end $$;

alter table public.asem_members enable row level security;
alter table public.asem_accounts enable row level security;
alter table public.asem_entries enable row level security;
drop policy if exists asem_members_read on public.asem_members;
create policy asem_members_read on public.asem_members for select to authenticated using (asem_is_member());
drop policy if exists asem_members_admin on public.asem_members;
create policy asem_members_admin on public.asem_members for all to authenticated using (asem_is_admin()) with check (asem_is_admin());
drop policy if exists asem_accounts_auth on public.asem_accounts;
create policy asem_accounts_auth on public.asem_accounts for all to authenticated using (asem_is_member()) with check (asem_is_member());
drop policy if exists asem_entries_auth on public.asem_entries;
create policy asem_entries_auth on public.asem_entries for all to authenticated using (asem_is_member()) with check (asem_is_member());
revoke all on public.asem_accounts, public.asem_entries, public.asem_members from anon;
revoke execute on function public.asem_balance_before(bigint,date), public.asem_week_summary(date), public.asem_is_member(), public.asem_is_admin(), public.asem_claim_first_admin() from anon, public;
grant execute on function public.asem_balance_before(bigint,date), public.asem_week_summary(date), public.asem_is_member(), public.asem_is_admin(), public.asem_claim_first_admin() to authenticated;
-- تكويد الحسابات: عملاء 1xxxx وموردين 2xxxx
-- عملاء شركات 11001...  عملاء محاجر 12001...  سواقين 21001...  محاجر 22001...
alter table public.asem_accounts add column if not exists code text unique;

create or replace function public.asem_code_base(p_type text)
returns int language sql immutable as $$
  select case p_type when 'عميل شركة' then 11000 when 'عميل محجر' then 12000
                     when 'سواق' then 21000 when 'محجر' then 22000 end;
$$;

create or replace function public.asem_set_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.code is null or new.code = '' then
    select (coalesce(max(code::int), asem_code_base(new.type)) + 1)::text into new.code
    from asem_accounts where type = new.type and code ~ '^[0-9]+$'
      and code::int between asem_code_base(new.type) and asem_code_base(new.type) + 999;
  end if;
  return new;
end $$;
revoke execute on function public.asem_set_code() from anon, authenticated, public;

drop trigger if exists asem_accounts_code on public.asem_accounts;
create trigger asem_accounts_code before insert on public.asem_accounts
for each row execute function public.asem_set_code();

-- تكويد الحسابات الموجودة قبل كده
update public.asem_accounts a set code = sub.c from (
  select id, (asem_code_base(type) + row_number() over (partition by type order by id))::text c
  from public.asem_accounts where code is null) sub
where a.id = sub.id;
-- تكويد الجرارات بالتكعيب (زي برنامج الكسارة)
create table if not exists public.asem_vehicles (
  id bigint generated always as identity primary key,
  plate text not null unique,
  trailer text,
  cube numeric(10,2),
  driver_id bigint references public.asem_accounts(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);
alter table public.asem_vehicles enable row level security;
drop policy if exists asem_vehicles_auth on public.asem_vehicles;
create policy asem_vehicles_auth on public.asem_vehicles for all to authenticated using (asem_is_member()) with check (asem_is_member());
revoke all on public.asem_vehicles from anon;

-- خانة الشركة لكل حساب
alter table public.asem_accounts add column if not exists company text;
