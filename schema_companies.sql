-- تعدد الشركات: كل شركة بحساباتها لوحدها (يتشغل مرة واحدة، وآمن لو اتشغل تاني)
create table if not exists public.ezz_companies (
  id bigint generated always as identity primary key,
  name text not null unique,
  created_at timestamptz not null default now()
);
insert into public.ezz_companies(name)
select 'عز الدين للمقاولات العامة والتوريدات' where not exists (select 1 from public.ezz_companies);

create table if not exists public.ezz_company_users (
  company_id bigint not null references public.ezz_companies(id) on delete cascade,
  email text not null,
  is_admin boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (company_id, email)
);

-- ربط البيانات الموجودة بشركة عز الدين
alter table public.ezz_accounts add column if not exists company text;
alter table public.ezz_accounts add column if not exists company_id bigint references public.ezz_companies(id);
alter table public.ezz_entries  add column if not exists company_id bigint references public.ezz_companies(id);
update public.ezz_accounts set company_id = (select min(id) from public.ezz_companies) where company_id is null;
update public.ezz_entries e set company_id = a.company_id from public.ezz_accounts a where a.id = e.account_id and e.company_id is null;
alter table public.ezz_accounts alter column company_id set not null;
alter table public.ezz_entries  alter column company_id set not null;
do $$ begin
  if to_regclass('public.ezz_vehicles') is not null then
    alter table public.ezz_vehicles add column if not exists company_id bigint references public.ezz_companies(id);
    update public.ezz_vehicles set company_id = (select min(id) from public.ezz_companies) where company_id is null;
    alter table public.ezz_vehicles alter column company_id set not null;
    alter table public.ezz_vehicles drop constraint if exists ezz_vehicles_plate_key;
    create unique index if not exists ezz_vehicles_co_plate on public.ezz_vehicles(company_id, plate);
  end if;
end $$;

-- نفس الاسم أو الكود ممكن يتكرر في شركتين مختلفتين
alter table public.ezz_accounts drop constraint if exists ezz_accounts_name_key;
alter table public.ezz_accounts drop constraint if exists ezz_accounts_code_key;
create unique index if not exists ezz_accounts_co_name on public.ezz_accounts(company_id, name);
create index if not exists ezz_entries_company on public.ezz_entries(company_id);

-- الحركة دايمًا تبع شركة الحساب بتاعها
create or replace function public.ezz_entry_company()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select company_id into new.company_id from ezz_accounts where id = new.account_id;
  return new;
end $$;
revoke execute on function public.ezz_entry_company() from anon, authenticated, public;
drop trigger if exists ezz_entries_company on public.ezz_entries;
create trigger ezz_entries_company before insert or update of account_id on public.ezz_entries
for each row execute function public.ezz_entry_company();

-- أكواد الحسابات بتتعد لكل شركة لوحدها
alter table public.ezz_accounts add column if not exists code text;
create unique index if not exists ezz_accounts_co_code on public.ezz_accounts(company_id, code);
create or replace function public.ezz_code_base(p_type text)
returns int language sql immutable as $$
  select case p_type when 'عميل شركة' then 11000 when 'عميل محجر' then 12000
                     when 'سواق' then 21000 when 'محجر' then 22000 end;
$$;
create or replace function public.ezz_set_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.code is null or new.code = '' then
    select (coalesce(max(code::int), ezz_code_base(new.type)) + 1)::text into new.code
    from ezz_accounts where type = new.type and company_id = new.company_id and code ~ '^[0-9]+$'
      and code::int between ezz_code_base(new.type) and ezz_code_base(new.type) + 999;
  end if;
  return new;
end $$;
revoke execute on function public.ezz_set_code() from anon, authenticated, public;
drop trigger if exists ezz_accounts_code on public.ezz_accounts;
create trigger ezz_accounts_code before insert on public.ezz_accounts
for each row execute function public.ezz_set_code();

-- الصلاحيات: مديرين البرنامج (ezz_members) يشوفوا كل الشركات، وموظف الشركة يشوف شركته بس
create or replace function public.ezz_can(cid bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select ezz_is_member() or exists(select 1 from ezz_company_users
    where company_id = cid and lower(email) = lower(auth.jwt()->>'email'));
$$;
create or replace function public.ezz_can_admin(cid bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select ezz_is_admin() or exists(select 1 from ezz_company_users
    where company_id = cid and is_admin and lower(email) = lower(auth.jwt()->>'email'));
$$;
create or replace function public.ezz_claim_first_admin()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists(select 1 from ezz_members) then
    return ezz_is_member() or exists(select 1 from ezz_company_users where lower(email) = lower(auth.jwt()->>'email'));
  end if;
  insert into ezz_members(email,is_admin) values (lower(auth.jwt()->>'email'), true);
  return true;
end $$;
revoke execute on function public.ezz_can(bigint), public.ezz_can_admin(bigint) from anon, public;
grant execute on function public.ezz_can(bigint), public.ezz_can_admin(bigint), public.ezz_claim_first_admin() to authenticated;

alter table public.ezz_companies enable row level security;
alter table public.ezz_company_users enable row level security;
drop policy if exists ezz_companies_read on public.ezz_companies;
create policy ezz_companies_read on public.ezz_companies for select to authenticated using (ezz_can(id));
drop policy if exists ezz_companies_admin on public.ezz_companies;
create policy ezz_companies_admin on public.ezz_companies for all to authenticated using (ezz_is_admin()) with check (ezz_is_admin());
drop policy if exists ezz_company_users_read on public.ezz_company_users;
create policy ezz_company_users_read on public.ezz_company_users for select to authenticated using (ezz_can(company_id));
drop policy if exists ezz_company_users_admin on public.ezz_company_users;
create policy ezz_company_users_admin on public.ezz_company_users for all to authenticated using (ezz_can_admin(company_id)) with check (ezz_can_admin(company_id));

drop policy if exists ezz_accounts_auth on public.ezz_accounts;
create policy ezz_accounts_auth on public.ezz_accounts for all to authenticated using (ezz_can(company_id)) with check (ezz_can(company_id));
drop policy if exists ezz_entries_auth on public.ezz_entries;
create policy ezz_entries_auth on public.ezz_entries for all to authenticated using (ezz_can(company_id)) with check (ezz_can(company_id));
do $$ begin
  if to_regclass('public.ezz_vehicles') is not null then
    execute 'drop policy if exists ezz_vehicles_auth on public.ezz_vehicles';
    execute 'create policy ezz_vehicles_auth on public.ezz_vehicles for all to authenticated using (ezz_can(company_id)) with check (ezz_can(company_id))';
  end if;
end $$;
revoke all on public.ezz_companies, public.ezz_company_users from anon;

-- أي حد يعمل حساب جديد ويكتب اسم شركته، بتتعمله شركة جديدة وبيبقى مديرها (ومش بيشوف غيرها)
create or replace function public.ezz_register_company(p_name text)
returns bigint language plpgsql security definer set search_path = public as $$
declare cid bigint; em text := lower(auth.jwt()->>'email');
begin
  if auth.uid() is null or coalesce(trim(p_name),'') = '' then raise exception 'not allowed'; end if;
  select company_id into cid from ezz_company_users where lower(email) = em limit 1;
  if cid is not null then return cid; end if;
  insert into ezz_companies(name) values (trim(p_name)) returning id into cid;
  insert into ezz_company_users(company_id, email, is_admin) values (cid, em, true);
  return cid;
end $$;
revoke execute on function public.ezz_register_company(text) from anon, public;
grant execute on function public.ezz_register_company(text) to authenticated;
